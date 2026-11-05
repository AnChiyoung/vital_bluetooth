import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bluetooth_device.dart';
import 'capabilities.dart';
import 'core/connection_options.dart';
import 'models.dart';
import 'platform/messages.g.dart';
import 'platform/platform_errors.dart';
import 'platform/platform_events.dart';
import 'uuid.dart';

/// One advertisement seen while scanning.
@immutable
class ScanResult {
  const ScanResult({
    required this.device,
    required this.rssi,
    required this.connectable,
    required this.serviceUuids,
    required this.manufacturerData,
    required this.serviceData,
    required this.timestamp,
    this.name,
    this.txPowerLevel,
  });

  final BluetoothDevice device;

  /// The advertised name, or the name the system remembers.
  final String? name;
  final int rssi;
  final bool connectable;
  final int? txPowerLevel;
  final List<String> serviceUuids;

  /// Company ID -> data.
  final Map<int, Uint8List> manufacturerData;

  /// Service UUID -> data.
  final Map<String, Uint8List> serviceData;

  /// When this result reached Dart.
  final DateTime timestamp;

  @override
  String toString() => 'ScanResult(${device.id}, $name, rssi: $rssi)';
}

/// A notification value that arrived in background mode while no Dart code
/// was handling its device. See [VitalBluetooth.takeBackgroundValues].
@immutable
class BackgroundValue {
  const BackgroundValue({
    required this.deviceId,
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.value,
    required this.timestamp,
  });

  final String deviceId;
  final String serviceUuid;
  final String characteristicUuid;
  final Uint8List value;

  /// When the platform received it.
  final DateTime timestamp;

  @override
  String toString() =>
      'BackgroundValue($deviceId, $characteristicUuid, $value, $timestamp)';
}

/// Entry point of vital_bluetooth.
///
/// There is one instance per app: `VitalBluetooth()` always returns it.
/// Every piece of state is a [ValueListenable] or a [Stream], so it plugs
/// into Riverpod, Provider, GetX or plain widgets without adapters.
class VitalBluetooth {
  /// The shared instance.
  factory VitalBluetooth() =>
      _instance ??= VitalBluetooth._(BleHostApi(), BleEvents()..attach());

  VitalBluetooth._(this._api, this._events) {
    _adapterSubscription = _events.adapterState.listen(
      (s) => _adapterState.value = adapterStateFrom(s),
    );
    unawaited(_loadAdapterState());
  }

  /// Uses [api] and [events] in place of the platform, for tests.
  @visibleForTesting
  factory VitalBluetooth.withApi(BleHostApi api, {BleEvents? events}) =>
      VitalBluetooth._(api, events ?? BleEvents());

  static VitalBluetooth? _instance;

  final BleHostApi _api;
  final BleEvents _events;
  final _adapterState = ValueNotifier(AdapterState.unknown);
  final _isScanning = ValueNotifier(false);
  final _devices = <String, BluetoothDevice>{};
  late final StreamSubscription<AdapterStateMessage> _adapterSubscription;
  _Scan? _scan;

  // --- Adapter and permissions ---

  /// What the current platform supports.
  Future<BluetoothCapabilities> getCapabilities() async {
    final caps = await guardPlatformCall(_api.getCapabilities);
    return BluetoothCapabilities(
      ble: caps.ble,
      classic: caps.classic,
      bonding: caps.bonding,
      connectionPriority: caps.connectionPriority,
      phy: caps.phy,
    );
  }

  /// The adapter state, kept up to date.
  ValueListenable<AdapterState> get adapterState => _adapterState;

  /// Asks the user to turn Bluetooth on (Android shows the system prompt).
  /// Throws [FeatureNotSupportedException] on other platforms.
  Future<void> turnOn() => guardPlatformCall(_api.turnOn);

  Future<PermissionStatus> permissionStatus() async =>
      permissionStatusFrom(await guardPlatformCall(_api.getPermissionStatus));

  /// Shows the system permission prompt if needed.
  Future<PermissionStatus> requestPermissions() async =>
      permissionStatusFrom(await guardPlatformCall(_api.requestPermissions));

  // --- Scanning ---

  /// Whether a scan is running.
  ValueListenable<bool> get isScanning => _isScanning;

  /// Scans while the stream is listened to.
  ///
  /// The scan starts on listen and stops when the subscription is
  /// cancelled, after [timeout], or when the platform ends it (an error is
  /// added first if it ended with one). Only one scan runs at a time:
  /// starting another ends the current one.
  ///
  /// [withServices] limits results to devices that advertise one of these
  /// services; iOS can only scan in the background with it.
  Stream<ScanResult> scan({
    List<String> withServices = const [],
    ScanMode mode = ScanMode.lowLatency,
    bool allowDuplicates = false,
    Duration? timeout,
  }) {
    final settings = ScanSettingsMessage(
      serviceUuids: withServices.map(BluetoothUuid.normalize).toList(),
      mode: ScanModeMessage.values[mode.index],
      allowDuplicates: allowDuplicates,
    );
    late final _Scan scan;
    final controller = StreamController<ScanResult>(
      onListen: () => unawaited(_startScan(scan, settings, timeout)),
      onCancel: () => _stopScan(scan),
    );
    scan = _Scan(controller);
    return controller.stream;
  }

  /// Stops the running scan, if any. Its stream closes.
  Future<void> stopScan() async {
    final scan = _scan;
    if (scan != null) await scan.controller.close();
  }

  Future<void> _startScan(
    _Scan scan,
    ScanSettingsMessage settings,
    Duration? timeout,
  ) async {
    final previous = _scan;
    if (previous != null) await _stopScan(previous);
    _scan = scan;
    scan.subscriptions
      ..add(
        _events.scanResults.listen((batch) {
          final now = DateTime.now();
          for (final r in batch) {
            scan.controller.add(_scanResultFrom(r, now));
          }
        }),
      )
      ..add(
        _events.scanStopped.listen((error) {
          if (error != null) {
            scan.controller.addError(fromPlatformErrorMessage(error));
          }
          unawaited(scan.controller.close());
        }),
      );
    try {
      await guardPlatformCall(() => _api.startScan(settings));
    } catch (e, st) {
      scan.controller.addError(e, st);
      await scan.controller.close();
      return;
    }
    if (scan.stopped) {
      // Cancelled while starting.
      await _ignoreErrors(_api.stopScan);
      return;
    }
    _isScanning.value = true;
    if (timeout != null) {
      scan.timer = Timer(timeout, () => unawaited(scan.controller.close()));
    }
  }

  Future<void> _stopScan(_Scan scan) async {
    if (scan.stopped) return;
    scan.stopped = true;
    scan.timer?.cancel();
    // Not awaited: cancelling a broadcast subscription returns a future
    // bound to the zone the events object was made in, and the stream's
    // done event waits for this callback to finish.
    for (final s in scan.subscriptions) {
      unawaited(s.cancel());
    }
    if (identical(_scan, scan)) {
      _scan = null;
      _isScanning.value = false;
      await _ignoreErrors(_api.stopScan);
    }
    if (!scan.controller.isClosed) await scan.controller.close();
  }

  ScanResult _scanResultFrom(ScanResultMessage r, DateTime now) {
    final found = device(r.deviceId);
    setDeviceName(found, r.name);
    return _scanResult(found, r, now);
  }

  ScanResult _scanResult(
    BluetoothDevice found,
    ScanResultMessage r,
    DateTime now,
  ) => ScanResult(
    device: found,
    name: r.name,
    rssi: r.rssi,
    connectable: r.connectable,
    txPowerLevel: r.txPowerLevel,
    serviceUuids: r.serviceUuids
        .map((u) => u.toLowerCase())
        .toList(growable: false),
    manufacturerData: r.manufacturerData,
    serviceData: {
      for (final e in r.serviceData.entries) e.key.toLowerCase(): e.value,
    },
    timestamp: now,
  );

  // --- Devices ---

  /// The options for devices created without explicit ones, including the
  /// ones made for scan results. Set it before scanning; devices that
  /// already exist keep theirs.
  ConnectionOptions defaultOptions = const ConnectionOptions();

  /// The device with [id]. The same object comes back for the same ID until
  /// it is disposed.
  ///
  /// [options] and [autoConnect] only apply when the object is created;
  /// without [options] it uses [defaultOptions]. [autoConnect] is Android
  /// only: the system connects whenever the device comes in range instead
  /// of giving up after about 30 seconds.
  BluetoothDevice device(
    String id, {
    ConnectionOptions? options,
    bool autoConnect = false,
  }) =>
      _devices[id] ??= BluetoothDevice.internal(
        id,
        _api,
        _events,
        options: options ?? defaultOptions,
        autoConnect: autoConnect,
        onDispose: (d) {
          if (identical(_devices[d.id], d)) _devices.remove(d.id);
        },
      );

  /// Devices the system is already connected to, for example by another
  /// app. They still need [BluetoothDevice.connect] before use here.
  Future<List<BluetoothDevice>> systemDevices({
    List<String> withServices = const [],
  }) async {
    final found = await guardPlatformCall(
      () => _api.getSystemDevices(
        withServices.map(BluetoothUuid.normalize).toList(),
      ),
    );
    return [for (final d in found) device(d.deviceId)];
  }

  // --- Background mode ---

  /// Keeps connections alive while the app is in the background, the screen
  /// is off, or the app's screen has been closed. Android only for now.
  ///
  /// Android shows an ongoing notification with [title] and [text] while it
  /// is on (the system requires it), and asks for the notification
  /// permission on Android 13+ the first time. From then on:
  ///
  /// * The app process is kept alive, so the link isn't dropped when the
  ///   app sits in the background.
  /// * Links outlive the app's screen. Closing it (back button, swiping it
  ///   away from recents) no longer disconnects.
  /// * While no screen is open, a dropped link is reconnected in native
  ///   code and notifications are turned back on, with no time limit.
  /// * Values that arrive while no Dart code handles the device are kept
  ///   (up to 10,000) for [takeBackgroundValues].
  ///
  /// When the app opens again, [restoreDevices] (or [device] with the same
  /// ID) picks the links back up. Pair it with
  /// `ReconnectPolicy.unlimited()` so the app keeps reconnecting while it
  /// is open too.
  ///
  /// Call it while the app is in the foreground; Android 12+ refuses it
  /// from the background. Needs the Bluetooth permissions first.
  Future<void> enableBackgroundMode({
    required String title,
    required String text,
  }) => guardPlatformCall(
    () => _api.enableBackgroundMode(
      BackgroundNotificationMessage(title: title, text: text),
    ),
  );

  /// Stops background mode and removes the notification. Connections stay
  /// up while the app runs, but closing the app closes them again.
  Future<void> disableBackgroundMode() =>
      guardPlatformCall(() async => _api.disableBackgroundMode());

  Future<bool> isBackgroundModeEnabled() =>
      guardPlatformCall(() async => _api.isBackgroundModeEnabled());

  /// The devices the platform kept connected (or is reconnecting) while the
  /// app's screen was closed in background mode, picked back up.
  ///
  /// Call it when the app starts. Each device becomes ready again with its
  /// notifications still on. [options] and [autoConnect] apply as in
  /// [device].
  Future<List<BluetoothDevice>> restoreDevices({
    ConnectionOptions? options,
    bool autoConnect = false,
  }) async {
    final sessions = await guardPlatformCall(() async => _api.getSessions());
    return [
      for (final s in sessions)
        device(s.deviceId, options: options, autoConnect: autoConnect),
    ];
  }

  /// Notification values received in background mode while no Dart code
  /// was handling their device, oldest first. Each value is returned once.
  ///
  /// Call it after [restoreDevices] to store what arrived while the app was
  /// closed. The buffer keeps the latest 10,000 values.
  Future<List<BackgroundValue>> takeBackgroundValues() async {
    final values = await guardPlatformCall(
      () async => _api.takeBufferedValues(),
    );
    return [
      for (final v in values)
        BackgroundValue(
          deviceId: v.characteristic.deviceId,
          serviceUuid: v.characteristic.serviceUuid.toLowerCase(),
          characteristicUuid: v.characteristic.characteristicUuid.toLowerCase(),
          value: v.value,
          timestamp: DateTime.fromMicrosecondsSinceEpoch(v.timestampMicros),
        ),
    ];
  }

  /// Releases everything. Only for tests; the shared instance lives as long
  /// as the app.
  @visibleForTesting
  Future<void> dispose() async {
    final scan = _scan;
    if (scan != null) await _stopScan(scan);
    for (final d in _devices.values.toList()) {
      await d.dispose();
    }
    unawaited(_adapterSubscription.cancel());
    _adapterState.dispose();
    _isScanning.dispose();
    if (identical(_instance, this)) _instance = null;
  }

  Future<void> _loadAdapterState() async {
    try {
      final state = await _api.getAdapterState();
      if (_adapterState.value == AdapterState.unknown) {
        _adapterState.value = adapterStateFrom(state);
      }
    } catch (_) {
      // Stays unknown; the next state event fixes it.
    }
  }

  static Future<void> _ignoreErrors(FutureOr<void> Function() call) async {
    try {
      await call();
    } catch (_) {}
  }
}

class _Scan {
  _Scan(this.controller);

  final StreamController<ScanResult> controller;
  final subscriptions = <StreamSubscription<Object?>>[];
  Timer? timer;
  bool stopped = false;
}
