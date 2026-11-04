import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/platform/messages.g.dart';
import 'package:vital_bluetooth/src/platform/platform_errors.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

VitalBluetoothException map(
  String code, {
  Object? details,
  String? message,
  BluetoothOperation? operation,
}) => fromPlatformException(
  PlatformException(code: code, message: message, details: details),
  deviceId: 'AA',
  operation: operation,
);

void main() {
  group('fromPlatformException', () {
    test('unsupported names the operation', () {
      expect(
        map('unsupported', operation: BluetoothOperation.requestMtu),
        isA<FeatureNotSupportedException>().having(
          (e) => e.feature,
          'feature',
          'requestMtu',
        ),
      );
    });

    test('poweredOff is an unavailable adapter', () {
      expect(
        map('poweredOff'),
        isA<AdapterUnavailableException>().having(
          (e) => e.reason,
          'reason',
          AdapterUnavailableReason.poweredOff,
        ),
      );
    });

    test('permissionDenied lists the missing permissions', () {
      expect(
        map('permissionDenied', details: ['android.permission.BLUETOOTH_SCAN']),
        isA<PermissionDeniedException>().having(
          (e) => e.permissions,
          'permissions',
          ['android.permission.BLUETOOTH_SCAN'],
        ),
      );
    });

    test('deviceNotFound keeps the device ID', () {
      expect(
        map('deviceNotFound'),
        isA<DeviceNotFoundException>().having((e) => e.deviceId, 'id', 'AA'),
      );
    });

    test('notConnected is a retryable disconnect', () {
      final error = map('notConnected', operation: BluetoothOperation.read);

      expect(
        error,
        isA<DeviceDisconnectedException>().having(
          (e) => e.operation,
          'operation',
          BluetoothOperation.read,
        ),
      );
      expect(error.isRetryable, isTrue);
    });

    test('connectionFailed keeps the raw status', () {
      final error = map('connectionFailed', details: '133');

      expect(
        error,
        isA<ConnectionFailedException>().having(
          (e) => e.platformCode,
          'platformCode',
          '133',
        ),
      );
      expect(error.isRetryable, isTrue);
    });

    test('gattError carries the ATT status', () {
      final error = map(
        'gattError',
        details: 0x05,
        operation: BluetoothOperation.write,
      );

      expect(
        error,
        isA<GattException>()
            .having((e) => e.status, 'status', 0x05)
            .having((e) => e.operation, 'operation', BluetoothOperation.write)
            .having((e) => e.requiresBonding, 'requiresBonding', isTrue),
      );
    });

    test('gattError without a status falls back to unknown', () {
      expect(map('gattError'), isA<UnknownBluetoothException>());
    });

    test('attributeNotFound names the UUID', () {
      expect(
        map(
          'attributeNotFound',
          details: '00002a37-0000-1000-8000-00805f9b34fb',
        ),
        isA<AttributeNotFoundException>().having(
          (e) => e.attributeUuid,
          'uuid',
          '00002a37-0000-1000-8000-00805f9b34fb',
        ),
      );
    });

    test('bondingFailed', () {
      expect(map('bondingFailed'), isA<BondingFailedException>());
    });

    test('a missing platform side gets a helpful message', () {
      expect(
        map('channel-error'),
        isA<UnknownBluetoothException>().having(
          (e) => e.message,
          'message',
          contains('not registered'),
        ),
      );
    });

    test('unknown codes keep the code and message', () {
      expect(
        map('somethingNew', message: 'boom'),
        isA<UnknownBluetoothException>()
            .having((e) => e.message, 'message', 'boom')
            .having((e) => e.platformCode, 'platformCode', 'somethingNew'),
      );
    });
  });

  test('fromPlatformErrorMessage reads the status from platformCode', () {
    final error = fromPlatformErrorMessage(
      PlatformErrorMessage(code: 'gattError', platformCode: '15'),
      deviceId: 'AA',
      operation: BluetoothOperation.read,
    );

    expect(error, isA<GattException>().having((e) => e.status, 'status', 15));
  });

  group('guardPlatformCall', () {
    test('passes results through', () async {
      expect(await guardPlatformCall(() async => 7), 7);
    });

    test('rethrows platform errors as VitalBluetoothException', () {
      expect(
        guardPlatformCall<void>(
          () => throw PlatformException(code: 'notConnected'),
          deviceId: 'AA',
          operation: BluetoothOperation.read,
        ),
        throwsA(isA<DeviceDisconnectedException>()),
      );
    });
  });
}
