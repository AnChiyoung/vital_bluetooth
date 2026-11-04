import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/core/device_connection.dart';
import 'package:vital_bluetooth/src/platform/ble_connection_driver.dart';
import 'package:vital_bluetooth/src/platform/messages.g.dart';
import 'package:vital_bluetooth/src/platform/platform_events.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

/// Answers host calls in place of a platform.
class FakeBleHostApi extends BleHostApi {
  final calls = <String>[];

  /// The next connect calls fail with these, in order.
  final connectErrors = <PlatformException>[];

  List<ServiceMessage> services = [
    ServiceMessage(
      uuid: '0000180d-0000-1000-8000-00805f9b34fb',
      instance: 0,
      isPrimary: true,
      characteristics: [],
      includedServices: [],
    ),
  ];

  @override
  Future<void> connect(String deviceId, bool autoConnect) async {
    calls.add('connect $deviceId $autoConnect');
    if (connectErrors.isNotEmpty) throw connectErrors.removeAt(0);
  }

  @override
  Future<List<ServiceMessage>> discoverServices(String deviceId) async {
    calls.add('discover $deviceId');
    return services;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    calls.add('disconnect $deviceId');
  }
}

void main() {
  late FakeBleHostApi api;
  late BleEvents events;

  setUp(() {
    api = FakeBleHostApi();
    events = BleEvents();
  });

  BleConnectionDriver driver({String id = 'AA', bool autoConnect = false}) =>
      BleConnectionDriver(id, api, events, autoConnect: autoConnect);

  test('connect passes the device ID and autoConnect', () async {
    await driver(autoConnect: true).connect();

    expect(api.calls, ['connect AA true']);
  });

  test('discoverServices keeps the services until disconnect', () async {
    final d = driver();

    await d.discoverServices();
    expect(d.services.single.uuid, '0000180d-0000-1000-8000-00805f9b34fb');

    await d.disconnect();
    expect(d.services, isEmpty);
  });

  test('platform errors become VitalBluetoothException', () {
    api.connectErrors.add(
      PlatformException(code: 'connectionFailed', details: '133'),
    );

    expect(
      driver().connect(),
      throwsA(
        isA<ConnectionFailedException>()
            .having((e) => e.deviceId, 'deviceId', 'AA')
            .having((e) => e.platformCode, 'platformCode', '133'),
      ),
    );
  });

  test('linkLost only reports drops of this device', () async {
    final drops = <VitalBluetoothException?>[];
    driver().linkLost.listen(drops.add);

    events
      ..onConnectionStateChanged(
        'BB',
        ConnectionStateMessage.disconnected,
        null,
      )
      ..onConnectionStateChanged('AA', ConnectionStateMessage.connected, null)
      ..onConnectionStateChanged(
        'AA',
        ConnectionStateMessage.disconnected,
        PlatformErrorMessage(code: 'notConnected', platformCode: '8'),
      );
    await Future<void>.delayed(Duration.zero);

    expect(drops, [
      isA<DeviceDisconnectedException>()
          .having((e) => e.deviceId, 'deviceId', 'AA')
          .having((e) => e.platformCode, 'platformCode', '8'),
    ]);
  });

  group('with DeviceConnection', () {
    test('connects, discovers and becomes ready', () {
      fakeAsync((async) {
        final connection = DeviceConnection('AA', driver());

        connection.connect();
        async.flushMicrotasks();

        expect(connection.value.isReady, isTrue);
        expect(api.calls, ['connect AA false', 'discover AA']);
      });
    });

    test('retries Android status 133 and then succeeds', () {
      fakeAsync((async) {
        final connection = DeviceConnection('AA', driver());
        api.connectErrors.add(
          PlatformException(code: 'connectionFailed', details: '133'),
        );

        connection.connect();
        async.elapse(const Duration(seconds: 1));

        expect(connection.value.isReady, isTrue);
        expect(api.calls, [
          'connect AA false',
          'disconnect AA',
          'connect AA false',
          'discover AA',
        ]);
      });
    });

    test('a dropped link starts reconnecting', () {
      fakeAsync((async) {
        final connection = DeviceConnection('AA', driver());
        connection.connect();
        async.flushMicrotasks();

        events.onConnectionStateChanged(
          'AA',
          ConnectionStateMessage.disconnected,
          PlatformErrorMessage(code: 'notConnected', platformCode: '8'),
        );
        async.flushMicrotasks();

        expect(connection.value.status, DeviceConnectionStatus.reconnecting);
        expect(connection.value.error?.platformCode, '8');

        async.elapse(const Duration(seconds: 1));
        expect(connection.value.isReady, isTrue);
      });
    });

    test('the drop caused by disconnect() does not reconnect', () {
      fakeAsync((async) {
        final connection = DeviceConnection('AA', driver());
        connection.connect();
        async.flushMicrotasks();

        connection.disconnect();
        events.onConnectionStateChanged(
          'AA',
          ConnectionStateMessage.disconnected,
          null,
        );
        async.elapse(const Duration(minutes: 1));

        expect(connection.value.status, DeviceConnectionStatus.disconnected);
        expect(api.calls.where((c) => c.startsWith('connect')), hasLength(1));
      });
    });
  });
}
