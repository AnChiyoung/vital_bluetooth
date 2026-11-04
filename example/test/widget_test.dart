import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth_example/main.dart';

void main() {
  testWidgets('shows the scan page', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('vital_bluetooth'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
  });
}
