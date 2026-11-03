import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vital_bluetooth_platform_interface.dart';

/// An implementation of [VitalBluetoothPlatform] that uses method channels.
class MethodChannelVitalBluetooth extends VitalBluetoothPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('vital_bluetooth');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
