import 'dart:async';

import '../core/device_connection.dart';
import '../core/errors.dart';
import '../core/operation.dart';
import 'messages.g.dart';
import 'platform_errors.dart';
import 'platform_events.dart';

/// [ConnectionDriver] for a BLE device, backed by the Pigeon host API.
class BleConnectionDriver implements ConnectionDriver {
  BleConnectionDriver(
    this.deviceId,
    this._api,
    BleEvents events, {
    this.autoConnect = false,
  }) : linkLost = events.connectionStates
           .where(
             (e) =>
                 e.deviceId == deviceId &&
                 e.state == ConnectionStateMessage.disconnected,
           )
           .map(
             (e) => DeviceDisconnectedException(
               deviceId,
               platformCode: e.error?.platformCode,
               platformMessage: e.error?.message,
             ),
           );

  final String deviceId;
  final BleHostApi _api;

  /// Android only: let the system connect whenever the device shows up,
  /// instead of failing after about 30 seconds.
  final bool autoConnect;

  List<ServiceMessage> _services = const [];

  /// The services found by the last [discoverServices].
  List<ServiceMessage> get services => _services;

  /// Every drop of this device's link. [DeviceConnection] ignores the ones
  /// it caused itself.
  @override
  final Stream<VitalBluetoothException?> linkLost;

  @override
  Future<void> connect() => guardPlatformCall(
    () => _api.connect(deviceId, autoConnect),
    deviceId: deviceId,
    operation: BluetoothOperation.connect,
  );

  @override
  Future<void> discoverServices() async {
    _services = await guardPlatformCall(
      () => _api.discoverServices(deviceId),
      deviceId: deviceId,
      operation: BluetoothOperation.discoverServices,
    );
  }

  @override
  Future<void> disconnect() async {
    _services = const [];
    await guardPlatformCall(
      () => _api.disconnect(deviceId),
      deviceId: deviceId,
      operation: BluetoothOperation.disconnect,
    );
  }
}
