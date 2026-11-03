import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

void main() {
  group('ReconnectPolicy.delayFor', () {
    test('backs off exponentially up to maxDelay', () {
      const policy = ReconnectPolicy(
        maxAttempts: 6,
        initialDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 10),
      );

      expect(
        [for (var i = 1; i <= 6; i++) policy.delayFor(i)!.inSeconds],
        [1, 2, 4, 8, 10, 10],
      );
    });

    test('gives up after maxAttempts', () {
      const policy = ReconnectPolicy(maxAttempts: 2);

      expect(policy.delayFor(2), isNotNull);
      expect(policy.delayFor(3), isNull);
    });

    test('unlimited never gives up', () {
      const policy = ReconnectPolicy.unlimited(maxDelay: Duration(seconds: 5));

      expect(policy.delayFor(1000), const Duration(seconds: 5));
    });

    test('none never reconnects', () {
      expect(const ReconnectPolicy.none().delayFor(1), isNull);
    });
  });

  test('DeviceConnectionState compares by value', () {
    expect(
      const DeviceConnectionState(
        DeviceConnectionStatus.reconnecting,
        reconnectAttempt: 2,
      ),
      const DeviceConnectionState(
        DeviceConnectionStatus.reconnecting,
        reconnectAttempt: 2,
      ),
    );
    expect(
      const DeviceConnectionState(DeviceConnectionStatus.ready),
      isNot(DeviceConnectionState.disconnected),
    );
  });
}
