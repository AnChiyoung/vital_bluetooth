import 'vital_bluetooth_platform_interface.dart';

export 'src/core/errors.dart';
export 'src/core/operation.dart';

class VitalBluetooth {
  Future<String?> getPlatformVersion() {
    return VitalBluetoothPlatform.instance.getPlatformVersion();
  }
}
