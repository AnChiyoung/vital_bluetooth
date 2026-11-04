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

  ScanResult _scanResultFrom(ScanResultMessage r, DateTime now) => ScanResult(
    device: device(r.deviceId),
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

  /// The device with [id]. The same object comes back for the same ID until
  /// it is disposed.
  ///
  /// [options] and [autoConnect] only apply when the object is created.
  /// [autoConnect] is Android only: the system connects whenever the device
  /// comes in range instead of giving up after about 30 seconds.
  BluetoothDevice device(
    String id, {
    ConnectionOptions options = const ConnectionOptions(),
    bool autoConnect = false,
  }) => _devices[id] ??= BluetoothDevice.internal(
    id,
    _api,
    _events,
    options: options,
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
