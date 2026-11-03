
import 'vital_bluetooth_platform_interface.dart';

class VitalBluetooth {
  Future<String?> getPlatformVersion() {
    return VitalBluetoothPlatform.instance.getPlatformVersion();
  }
}
