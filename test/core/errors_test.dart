import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

void main() {
  group('isRetryable', () {
    test('transient connection and timing failures are retryable', () {
      expect(
        ConnectionFailedException('AA', platformCode: '133').isRetryable,
        isTrue,
      );
      expect(const DeviceDisconnectedException('AA').isRetryable, isTrue);
      expect(
        OperationTimeoutException(
          'AA',
          BluetoothOperation.read,
          const Duration(seconds: 1),
        ).isRetryable,
        isTrue,
      );
      expect(
        AdapterUnavailableException(AdapterUnavailableReason.transitioning)
            .isRetryable,
        isTrue,
      );
    });

    test('failures that need user action are not retryable', () {
      expect(
        AdapterUnavailableException(AdapterUnavailableReason.poweredOff)
            .isRetryable,
        isFalse,
      );
      expect(PermissionDeniedException(['x']).isRetryable, isFalse);
      expect(
        const ConnectionFailedException('AA', retryable: false).isRetryable,
        isFalse,
      );
      expect(
        GattException('AA', BluetoothOperation.write, 0x03).isRetryable,
        isFalse,
      );
    });
  });

  test('GattException flags statuses that need bonding', () {
    for (final status in [0x05, 0x08, 0x0F]) {
      expect(
        GattException('AA', BluetoothOperation.read, status).requiresBonding,
        isTrue,
      );
    }
    expect(
      GattException('AA', BluetoothOperation.read, 0x02).requiresBonding,
      isFalse,
    );
  });

  test('toString includes the native code and message', () {
    final error = ConnectionFailedException(
      'AA',
      platformCode: '133',
      platformMessage: 'GATT_ERROR',
    );
    expect(
      error.toString(),
      'ConnectionFailedException: Failed to connect to AA '
      '(platformCode: 133) - GATT_ERROR',
    );
  });

  test('switch over the hierarchy is exhaustive', () {
    String describe(VitalBluetoothException e) => switch (e) {
      AdapterUnavailableException() => 'adapter',
      PermissionDeniedException() => 'permission',
      FeatureNotSupportedException() => 'feature',
      UnknownBluetoothException() => 'unknown',
      DeviceException() => 'device',
    };

    expect(describe(const DeviceNotFoundException('AA')), 'device');
    expect(describe(const UnknownBluetoothException('x')), 'unknown');
  });
}
