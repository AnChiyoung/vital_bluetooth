import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/platform/messages.g.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

class FakeBleHostApi extends BleHostApi {
  @override
  Future<CapabilitiesMessage> getCapabilities() async => CapabilitiesMessage(
    ble: true,
    classic: false,
    bonding: false,
    connectionPriority: false,
    phy: false,
  );
}

void main() {
  test('getCapabilities converts the platform answer', () async {
    final bluetooth = VitalBluetooth.withApi(FakeBleHostApi());

    expect(
      await bluetooth.getCapabilities(),
      const BluetoothCapabilities(
        ble: true,
        classic: false,
        bonding: false,
        connectionPriority: false,
        phy: false,
      ),
    );
  });
}
