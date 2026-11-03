import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';
import 'package:vital_bluetooth/vital_bluetooth_platform_interface.dart';
import 'package:vital_bluetooth/vital_bluetooth_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockVitalBluetoothPlatform
    with MockPlatformInterfaceMixin
    implements VitalBluetoothPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final VitalBluetoothPlatform initialPlatform =
      VitalBluetoothPlatform.instance;

  test('$MethodChannelVitalBluetooth is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelVitalBluetooth>());
  });

  test('getPlatformVersion', () async {
    VitalBluetooth vitalBluetoothPlugin = VitalBluetooth();
    MockVitalBluetoothPlatform fakePlatform = MockVitalBluetoothPlatform();
    VitalBluetoothPlatform.instance = fakePlatform;

    expect(await vitalBluetoothPlugin.getPlatformVersion(), '42');
  });
}
