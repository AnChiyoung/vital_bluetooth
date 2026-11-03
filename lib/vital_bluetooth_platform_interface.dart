import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'vital_bluetooth_method_channel.dart';

abstract class VitalBluetoothPlatform extends PlatformInterface {
  /// Constructs a VitalBluetoothPlatform.
  VitalBluetoothPlatform() : super(token: _token);

  static final Object _token = Object();

  static VitalBluetoothPlatform _instance = MethodChannelVitalBluetooth();

  /// The default instance of [VitalBluetoothPlatform] to use.
  ///
  /// Defaults to [MethodChannelVitalBluetooth].
  static VitalBluetoothPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VitalBluetoothPlatform] when
  /// they register themselves.
  static set instance(VitalBluetoothPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
