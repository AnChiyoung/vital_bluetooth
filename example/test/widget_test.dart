import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth_example/main.dart';

void main() {
  testWidgets('shows the app bar', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('vital_bluetooth example'), findsOneWidget);
  });
}
