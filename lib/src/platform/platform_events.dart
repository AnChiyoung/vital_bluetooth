import 'dart:async';

import 'package:flutter/services.dart';

import 'messages.g.dart';

typedef ConnectionStateEvent = ({
  String deviceId,
  ConnectionStateMessage state,
  PlatformErrorMessage? error,
});

typedef MtuEvent = ({String deviceId, int mtu});

typedef BondStateEvent = ({String deviceId, BondStateMessage state});

/// Receives the BLE events the platform sends and republishes them as
/// broadcast streams.
///
/// There is one instance per engine. Each [DeviceConnection] and scanner
/// listens to the streams it needs and filters by device ID.
class BleEvents implements BleFlutterApi {
  final _adapterState = StreamController<AdapterStateMessage>.broadcast();
  final _scanResults = StreamController<List<ScanResultMessage>>.broadcast();
  final _scanStopped = StreamController<PlatformErrorMessage?>.broadcast();
  final _connectionStates = StreamController<ConnectionStateEvent>.broadcast();
  final _characteristicValues =
      StreamController<List<CharacteristicValueMessage>>.broadcast();
  final _servicesChanged = StreamController<String>.broadcast();
  final _mtuChanged = StreamController<MtuEvent>.broadcast();
  final _bondStateChanged = StreamController<BondStateEvent>.broadcast();

  Stream<AdapterStateMessage> get adapterState => _adapterState.stream;

  /// Batches of scan results, in the order the platform saw them.
  Stream<List<ScanResultMessage>> get scanResults => _scanResults.stream;

  /// Emits when a scan ends without stopScan(), with the reason if any.
  Stream<PlatformErrorMessage?> get scanStopped => _scanStopped.stream;

  Stream<ConnectionStateEvent> get connectionStates => _connectionStates.stream;

  /// Batches of notification values for every device.
  Stream<List<CharacteristicValueMessage>> get characteristicValues =>
      _characteristicValues.stream;

  /// Device IDs whose services changed.
  Stream<String> get servicesChanged => _servicesChanged.stream;

  Stream<MtuEvent> get mtuChanged => _mtuChanged.stream;

  Stream<BondStateEvent> get bondStateChanged => _bondStateChanged.stream;

  /// Starts receiving events from the platform.
  void attach({BinaryMessenger? binaryMessenger}) =>
      BleFlutterApi.setUp(this, binaryMessenger: binaryMessenger);

  /// Stops receiving events and closes every stream.
  Future<void> dispose({BinaryMessenger? binaryMessenger}) async {
    BleFlutterApi.setUp(null, binaryMessenger: binaryMessenger);
    await Future.wait([
      _adapterState.close(),
      _scanResults.close(),
      _scanStopped.close(),
      _connectionStates.close(),
      _characteristicValues.close(),
      _servicesChanged.close(),
      _mtuChanged.close(),
      _bondStateChanged.close(),
    ]);
  }

  @override
  void onAdapterStateChanged(AdapterStateMessage state) =>
      _adapterState.add(state);

  @override
  void onScanResults(List<ScanResultMessage> results) =>
      _scanResults.add(results);

  @override
  void onScanStopped(PlatformErrorMessage? error) => _scanStopped.add(error);

  @override
  void onConnectionStateChanged(
    String deviceId,
    ConnectionStateMessage state,
    PlatformErrorMessage? error,
  ) => _connectionStates.add((deviceId: deviceId, state: state, error: error));

  @override
  void onCharacteristicValues(List<CharacteristicValueMessage> values) =>
      _characteristicValues.add(values);

  @override
  void onServicesChanged(String deviceId) => _servicesChanged.add(deviceId);

  @override
  void onMtuChanged(String deviceId, int mtu) =>
      _mtuChanged.add((deviceId: deviceId, mtu: mtu));

  @override
  void onBondStateChanged(String deviceId, BondStateMessage state) =>
      _bondStateChanged.add((deviceId: deviceId, state: state));
}

typedef ClassicDataEvent = ({String deviceId, Uint8List data});

typedef ClassicDisconnectEvent = ({
  String deviceId,
  PlatformErrorMessage? error,
});

/// Receives the Classic (RFCOMM) events the platform sends.
class ClassicEvents implements ClassicFlutterApi {
  final _discovered = StreamController<ClassicDeviceMessage>.broadcast();
  final _discoveryFinished = StreamController<void>.broadcast();
  final _data = StreamController<ClassicDataEvent>.broadcast();
  final _disconnected = StreamController<ClassicDisconnectEvent>.broadcast();

  Stream<ClassicDeviceMessage> get discovered => _discovered.stream;

  Stream<void> get discoveryFinished => _discoveryFinished.stream;

  Stream<ClassicDataEvent> get data => _data.stream;

  Stream<ClassicDisconnectEvent> get disconnected => _disconnected.stream;

  void attach({BinaryMessenger? binaryMessenger}) =>
      ClassicFlutterApi.setUp(this, binaryMessenger: binaryMessenger);

  Future<void> dispose({BinaryMessenger? binaryMessenger}) async {
    ClassicFlutterApi.setUp(null, binaryMessenger: binaryMessenger);
    await Future.wait([
      _discovered.close(),
      _discoveryFinished.close(),
      _data.close(),
      _disconnected.close(),
    ]);
  }

  @override
  void onDeviceDiscovered(ClassicDeviceMessage device) =>
      _discovered.add(device);

  @override
  void onDiscoveryFinished() => _discoveryFinished.add(null);

  @override
  void onData(String deviceId, Uint8List data) =>
      _data.add((deviceId: deviceId, data: data));

  @override
  void onDisconnected(String deviceId, PlatformErrorMessage? error) =>
      _disconnected.add((deviceId: deviceId, error: error));
}
