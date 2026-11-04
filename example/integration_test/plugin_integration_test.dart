// Runs on a real device or emulator, so it talks to the native side.
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the platform answers getCapabilities', (tester) async {
    final caps = await VitalBluetooth().getCapabilities();

    expect(caps.ble, isTrue);
  });
}
