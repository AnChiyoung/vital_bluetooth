import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/connection_options.dart';
import 'core/connection_state.dart';
import 'core/device_connection.dart';
import 'core/errors.dart';
import 'core/operation.dart';
import 'models.dart';
import 'platform/ble_connection_driver.dart';
import 'platform/messages.g.dart';
import 'platform/platform_errors.dart';
import 'platform/platform_events.dart';
import 'uuid.dart';

/// A BLE device, connected or not.
///
/// Get one from [VitalBluetooth.device] or a [ScanResult]. There is one
/// object per device ID, so it is safe to keep and compare.
///
/// The connection retries failed connects and reconnects after a drop
/// according to [options]. After a reconnect it turns notifications back on
/// for every characteristic that had them on, so a stream from
/// [BluetoothCharacteristic.values] keeps delivering.
class BluetoothDevice {
  /// Used by [VitalBluetooth.device]; apps call that instead.
  BluetoothDevice.internal(
    this.id,
    this._api,
    this._events, {
    required this.options,
    required bool autoConnect,
    required this._onDispose,
  }) {
    _driver = BleConnectionDriver(id, _api, _events, autoConnect: autoConnect);
    _connection = DeviceConnection(id, _driver, options: options);
    _connection.state.addListener(_onConnectionChanged);
    _mtuSubscription = _events.mtuChanged
        .where((e) => e.deviceId == id)
        .listen((e) => _mtu.value = e.mtu);
    unawaited(_restore());
  }

  /// MAC address on Android and Windows, a UUID on iOS and macOS. The
  /// iOS/macOS UUID is stable on one phone but differs between phones.
  final String id;

  final ConnectionOptions options;

  final BleHostApi _api;
  final BleEvents _events;
  final void Function(BluetoothDevice) _onDispose;
  late final BleConnectionDriver _driver;
  late final DeviceConnection _connection;
  late final StreamSubscription<MtuEvent> _mtuSubscription;
  final _mtu = ValueNotifier<int>(23);
  final _services = ValueNotifier<List<BluetoothService>>(const []);
  final _subscribed = <BluetoothCharacteristic>{};

  /// Notifications the platform kept on while no Dart code ran, matched to
  /// characteristics once services are known.
  List<CharacteristicAddressMessage>? _restoredSubscriptions;
  bool _disposed = false;

  /// The connection state. Use it with ValueListenableBuilder, or wrap it
  /// for Riverpod, Provider or GetX.
  ValueListenable<DeviceConnectionState> get connectionState =>
      _connection.state;

  /// Every connection state change. Doesn't replay the current state.
  Stream<DeviceConnectionState> get connectionStateStream =>
      _connection.stateStream;

  bool get isReady => _connection.value.isReady;

  /// The services found when the device last became ready.
  ValueListenable<List<BluetoothService>> get services => _services;

  /// The current ATT MTU. A single write without response carries up to
  /// `mtu - 3` bytes.
  ValueListenable<int> get mtu => _mtu;

  /// Connects and discovers services. Retries according to [options].
  Future<void> connect() => _connection.connect();

  /// Disconnects and stops reconnecting.
  Future<void> disconnect() => _connection.disconnect();

  /// Finds a characteristic by UUID, in any form [BluetoothUuid.normalize]
  /// accepts. Returns null if the device isn't ready or doesn't have it.
  ///
  /// If a device has the same characteristic twice, this returns the first;
  /// go through [services] to pick another.
  BluetoothCharacteristic? characteristic(
    String serviceUuid,
    String characteristicUuid,
  ) {
    final service = BluetoothUuid.normalize(serviceUuid);
    final characteristic = BluetoothUuid.normalize(characteristicUuid);
    for (final s in _services.value) {
      if (s.uuid != service) continue;
      for (final c in s.characteristics) {
        if (c.uuid == characteristic) return c;
      }
    }
    return null;
  }

  /// Asks for a larger MTU and returns the one the devices agreed on.
  /// iOS and macOS choose it themselves and just return the current one.
  Future<int> requestMtu(int mtu) =>
      _run(BluetoothOperation.requestMtu, () async {
        final agreed = await _api.requestMtu(id, mtu);
        _mtu.value = agreed;
        return agreed;
      });

  /// The largest value one write can carry right now.
  Future<int> maximumWriteLength({bool withResponse = true}) =>
      guardPlatformCall(
        () async => _api.getMaximumWriteLength(id, withResponse),
        deviceId: id,
      );

  /// Android only. [ConnectionPriority.high] speeds up transfers at the
  /// cost of battery.
  Future<void> requestConnectionPriority(ConnectionPriority priority) => _run(
    BluetoothOperation.requestConnectionPriority,
    () => _api.requestConnectionPriority(
      id,
      ConnectionPriorityMessage.values[priority.index],
    ),
  );

  /// Android 8+ only.
  Future<void> setPreferredPhy({required Phy tx, required Phy rx}) => _run(
    BluetoothOperation.setPreferredPhy,
    () => _api.setPreferredPhy(
      id,
      PhyMessage.values[tx.index],
      PhyMessage.values[rx.index],
    ),
  );

  Future<int> readRssi() =>
      _run(BluetoothOperation.readRssi, () => _api.readRssi(id));

  Future<BondState> bondState() => guardPlatformCall(
    () async => bondStateFrom(await _api.getBondState(id)),
    deviceId: id,
  );

  /// Bond state changes for this device.
  Stream<BondState> get bondStateStream => _events.bondStateChanged
      .where((e) => e.deviceId == id)
      .map((e) => bondStateFrom(e.state));

  /// Pairs with the device. Android and Windows; iOS and macOS pair on
  /// their own when a characteristic needs it.
  Future<void> createBond() => guardPlatformCall(
    () => _api.createBond(id),
    deviceId: id,
    operation: BluetoothOperation.bond,
  );

  Future<void> removeBond() => guardPlatformCall(
    () => _api.removeBond(id),
    deviceId: id,
    operation: BluetoothOperation.removeBond,
  );

  /// Disconnects and releases everything. A later [VitalBluetooth.device]
  /// call with the same ID makes a new object.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onDispose(this);
    _connection.state.removeListener(_onConnectionChanged);
    await _connection.dispose();
    unawaited(_mtuSubscription.cancel());
    _mtu.dispose();
    _services.dispose();
  }

  /// Runs a GATT call through the connection's queue, so the platform only
  /// sees one at a time, and turns platform errors into
  /// [VitalBluetoothException]s.
  Future<T> _run<T>(BluetoothOperation operation, Future<T> Function() call) =>
      _connection.run(
        operation,
        () => guardPlatformCall(call, deviceId: id, operation: operation),
      );

  void _onConnectionChanged() {
    final ready = _connection.value.isReady;
    if (ready) {
      final next = _driver.services
          .map((s) => BluetoothService._from(this, s))
          .toList(growable: false);
      _services.value = next;
      final restored = _restoredSubscriptions;
      _restoredSubscriptions = null;
      for (final address
          in restored ?? const <CharacteristicAddressMessage>[]) {
        final match = _findAddress(next, address);
        if (match != null) _subscribed.add(match);
      }
      if (_subscribed.isNotEmpty) _restoreNotifications(next);
    } else if (_connection.value.status ==
        DeviceConnectionStatus.disconnected) {
      _services.value = const [];
      _mtu.value = 23;
    }
  }

  /// Turns notifications back on after a reconnect. The new characteristic
  /// objects replace the old ones in the subscription set.
  void _restoreNotifications(List<BluetoothService> services) {
    final previous = _subscribed.toList();
    _subscribed.clear();
    for (final old in previous) {
      final match = _find(services, old);
      if (match == null) continue;
      _subscribed.add(match);
      unawaited(
        match._setNotifyNow(true).catchError((Object _) {
          // The values stream just stays quiet; the app sees the state.
        }),
      );
    }
  }

  /// Picks up a link the platform kept alive in background mode, if any.
  /// Asking also tells the platform that Dart now handles this device's
  /// values, so they stop going to the background buffer.
  Future<void> _restore() async {
    final SessionMessage? session;
    try {
      session = await _api.getSession(id);
    } catch (_) {
      return; // Nothing to restore on this platform.
    }
    if (session == null || _disposed) return;
    _restoredSubscriptions = session.subscribed;
    _connection.resume(connected: session.connected);
  }

  static BluetoothCharacteristic? _find(
    List<BluetoothService> services,
    BluetoothCharacteristic old,
  ) => _match(
    services,
    old.serviceUuid,
    old.serviceInstance,
    old.uuid,
    old.instance,
  );

  static BluetoothCharacteristic? _findAddress(
    List<BluetoothService> services,
    CharacteristicAddressMessage a,
  ) => _match(
    services,
    a.serviceUuid.toLowerCase(),
    a.serviceInstance,
    a.characteristicUuid.toLowerCase(),
    a.characteristicInstance,
  );

  static BluetoothCharacteristic? _match(
    List<BluetoothService> services,
    String serviceUuid,
    int serviceInstance,
    String uuid,
    int instance,
  ) {
    for (final s in services) {
      if (s.uuid != serviceUuid || s.instance != serviceInstance) continue;
      for (final c in s.characteristics) {
        if (c.uuid == uuid && c.instance == instance) return c;
      }
    }
    return null;
  }

  @override
  String toString() => 'BluetoothDevice($id)';
}

/// A GATT service on a [BluetoothDevice].
class BluetoothService {
  BluetoothService._(
    this.device,
    this.uuid,
    this.instance,
    this.isPrimary,
    this.includedServices,
  );

  factory BluetoothService._from(BluetoothDevice device, ServiceMessage m) {
    final service = BluetoothService._(
      device,
      m.uuid.toLowerCase(),
      m.instance,
      m.isPrimary,
      m.includedServices.map((u) => u.toLowerCase()).toList(growable: false),
    );
    service.characteristics = m.characteristics
        .map((c) => BluetoothCharacteristic._(service, c))
        .toList(growable: false);
    return service;
  }

  final BluetoothDevice device;
  final String uuid;

  /// Tells apart two services with the same UUID.
  final int instance;
  final bool isPrimary;
  final List<String> includedServices;
  late final List<BluetoothCharacteristic> characteristics;

  @override
  String toString() => 'BluetoothService($uuid)';
}

/// One value received from a notification or indication.
@immutable
class CharacteristicValue {
  const CharacteristicValue(this.value, this.timestamp);

  final Uint8List value;

  /// When the platform received it. Values reach Dart in batches, so use
  /// this rather than the time the stream delivers it.
  final DateTime timestamp;
}

/// A GATT characteristic: read it, write it, or subscribe to it.
class BluetoothCharacteristic {
  BluetoothCharacteristic._(this.service, CharacteristicMessage m)
    : uuid = m.uuid.toLowerCase(),
      instance = m.instance,
      properties = propertiesFrom(m.properties),
      descriptors = m.descriptors
          .map((d) => d.uuid.toLowerCase())
          .toList(growable: false);

  final BluetoothService service;
  final String uuid;

  /// Tells apart two characteristics with the same UUID.
  final int instance;
  final CharacteristicProperties properties;

  /// UUIDs of its descriptors.
  final List<String> descriptors;

  BluetoothDevice get device => service.device;
  String get serviceUuid => service.uuid;
  int get serviceInstance => service.instance;

  CharacteristicAddressMessage get _address => CharacteristicAddressMessage(
    deviceId: device.id,
    serviceUuid: serviceUuid,
    serviceInstance: serviceInstance,
    characteristicUuid: uuid,
    characteristicInstance: instance,
  );

  bool _matches(CharacteristicAddressMessage a) =>
      a.deviceId == device.id &&
      a.characteristicInstance == instance &&
      a.serviceInstance == serviceInstance &&
      a.characteristicUuid.toLowerCase() == uuid &&
      a.serviceUuid.toLowerCase() == serviceUuid;

  bool get isNotifying => device._subscribed.any(
    (c) =>
        c.uuid == uuid &&
        c.instance == instance &&
        c.serviceUuid == serviceUuid &&
        c.serviceInstance == serviceInstance,
  );

  Future<Uint8List> read() => device._run(
    BluetoothOperation.read,
    () => _api.readCharacteristic(_address),
  );

  /// Writes [value]. Without response is faster but the device doesn't
  /// confirm it; keep each value within [BluetoothDevice.maximumWriteLength].
  Future<void> write(List<int> value, {bool withResponse = true}) =>
      device._run(
        withResponse
            ? BluetoothOperation.write
            : BluetoothOperation.writeWithoutResponse,
        () => _api.writeCharacteristic(
          _address,
          Uint8List.fromList(value),
          withResponse,
        ),
      );

  /// Turns notifications (or indications) on or off. While on, they stay
  /// on across reconnects until turned off.
  Future<void> setNotify(bool enable) async {
    await _setNotifyNow(enable);
    final subscribed = device._subscribed;
    subscribed.removeWhere(
      (c) =>
          c.uuid == uuid &&
          c.instance == instance &&
          c.serviceUuid == serviceUuid &&
          c.serviceInstance == serviceInstance,
    );
    if (enable) subscribed.add(this);
  }

  Future<void> _setNotifyNow(bool enable) => device._run(
    BluetoothOperation.setNotify,
    () => _api.setNotify(_address, enable),
  );

  /// Values from notifications or indications, with the time each arrived.
  /// Listening doesn't turn them on; call [setNotify] for that.
  Stream<CharacteristicValue> get valuesWithTime => device
      ._events
      .characteristicValues
      .expand((batch) => batch)
      .where((v) => _matches(v.characteristic))
      .map(
        (v) => CharacteristicValue(
          v.value,
          DateTime.fromMicrosecondsSinceEpoch(v.timestampMicros),
        ),
      );

  /// Values from notifications or indications.
  Stream<Uint8List> get values => valuesWithTime.map((v) => v.value);

  Future<Uint8List> readDescriptor(String descriptorUuid) => device._run(
    BluetoothOperation.readDescriptor,
    () =>
        _api.readDescriptor(_address, BluetoothUuid.normalize(descriptorUuid)),
  );

  Future<void> writeDescriptor(String descriptorUuid, List<int> value) =>
      device._run(
        BluetoothOperation.writeDescriptor,
        () => _api.writeDescriptor(
          _address,
          BluetoothUuid.normalize(descriptorUuid),
          Uint8List.fromList(value),
        ),
      );

  BleHostApi get _api => device._api;

  @override
  String toString() => 'BluetoothCharacteristic($uuid)';
}
