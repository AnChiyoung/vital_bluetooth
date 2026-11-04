import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/platform/messages.g.dart';
import 'package:vital_bluetooth/src/platform/platform_events.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

const heartRateService = '0000180d-0000-1000-8000-00805f9b34fb';
const heartRateMeasurement = '00002a37-0000-1000-8000-00805f9b34fb';
const bodySensorLocation = '00002a38-0000-1000-8000-00805f9b34fb';

CharacteristicPropertiesMessage props({
  bool read = false,
  bool notify = false,
}) => CharacteristicPropertiesMessage(
  broadcast: false,
  read: read,
  writeWithoutResponse: false,
  write: true,
  notify: notify,
  indicate: false,
  authenticatedSignedWrites: false,
  extendedProperties: false,
);

/// Answers host calls in place of a platform and records them.
class FakeBleHostApi extends BleHostApi {
  final calls = <String>[];
  AdapterStateMessage adapter = AdapterStateMessage.poweredOn;
  PlatformException? startScanError;
  final sessions = <String, SessionMessage>{};
  final buffered = <CharacteristicValueMessage>[];
  BackgroundNotificationMessage? background;

  @override
  Future<CapabilitiesMessage> getCapabilities() async => CapabilitiesMessage(
    ble: true,
    classic: false,
    bonding: false,
    connectionPriority: false,
    phy: false,
  );

  @override
  Future<AdapterStateMessage> getAdapterState() async => adapter;

  @override
  Future<PermissionStatusMessage> requestPermissions() async =>
      PermissionStatusMessage.permanentlyDenied;

  @override
  Future<void> startScan(ScanSettingsMessage settings) async {
    calls.add('startScan ${settings.serviceUuids}');
    if (startScanError != null) throw startScanError!;
  }

  @override
  Future<void> stopScan() async => calls.add('stopScan');

  @override
  Future<void> connect(String deviceId, bool autoConnect) async =>
      calls.add('connect $deviceId');

  @override
  Future<void> disconnect(String deviceId, bool forget) async =>
      calls.add('disconnect $deviceId');

  @override
  Future<List<ServiceMessage>> discoverServices(String deviceId) async => [
    ServiceMessage(
      uuid: heartRateService,
      instance: 0,
      isPrimary: true,
      includedServices: [],
      characteristics: [
        CharacteristicMessage(
          uuid: heartRateMeasurement,
          instance: 0,
          properties: props(notify: true),
          descriptors: [
            DescriptorMessage(uuid: '00002902-0000-1000-8000-00805f9b34fb'),
          ],
        ),
        CharacteristicMessage(
          uuid: bodySensorLocation,
          instance: 0,
          properties: props(read: true),
          descriptors: [],
        ),
      ],
    ),
  ];

  @override
  Future<Uint8List> readCharacteristic(
    CharacteristicAddressMessage characteristic,
  ) async {
    calls.add('read ${characteristic.characteristicUuid.substring(4, 8)}');
    return Uint8List.fromList([1]);
  }

  @override
  Future<void> setNotify(
    CharacteristicAddressMessage characteristic,
    bool enable,
  ) async => calls.add(
    'notify ${characteristic.characteristicUuid.substring(4, 8)} $enable',
  );

  @override
  Future<int> requestMtu(String deviceId, int mtu) async => 185;

  @override
  Future<void> enableBackgroundMode(
    BackgroundNotificationMessage notification,
  ) async => background = notification;

  @override
  Future<SessionMessage?> getSession(String deviceId) async =>
      sessions[deviceId];

  @override
  Future<List<SessionMessage>> getSessions() async => sessions.values.toList();

  @override
  Future<List<CharacteristicValueMessage>> takeBufferedValues() async =>
      List.of(buffered);
}

ScanResultMessage scanResult(String id, {String? name}) => ScanResultMessage(
  deviceId: id,
  name: name,
  rssi: -60,
  connectable: true,
  serviceUuids: [heartRateService],
  manufacturerData: {},
  serviceData: {},
);

void main() {
  late FakeBleHostApi api;
  late BleEvents events;
  late VitalBluetooth bluetooth;

  setUp(() {
    api = FakeBleHostApi();
    events = BleEvents();
    bluetooth = VitalBluetooth.withApi(api, events: events);
  });

  tearDown(() => bluetooth.dispose());

  test('BluetoothUuid accepts short forms', () {
    expect(BluetoothUuid.normalize('180D'), heartRateService);
    expect(BluetoothUuid.normalize('0x2a37'), heartRateMeasurement);
    expect(
      BluetoothUuid.normalize(heartRateService.toUpperCase()),
      heartRateService,
    );
    expect(() => BluetoothUuid.normalize('xyz'), throwsFormatException);
  });

  test('getCapabilities converts the platform answer', () async {
    final caps = await bluetooth.getCapabilities();

    expect(caps.ble, isTrue);
    expect(caps.classic, isFalse);
  });

  test('adapterState loads the current state and follows events', () async {
    await Future<void>.delayed(Duration.zero);
    expect(bluetooth.adapterState.value, AdapterState.poweredOn);

    events.onAdapterStateChanged(AdapterStateMessage.poweredOff);
    await Future<void>.delayed(Duration.zero);

    expect(bluetooth.adapterState.value, AdapterState.poweredOff);
  });

  test('requestPermissions converts the status', () async {
    expect(
      await bluetooth.requestPermissions(),
      PermissionStatus.permanentlyDenied,
    );
  });

  group('scan', () {
    test('starts on listen, delivers results and stops on cancel', () async {
      final results = <ScanResult>[];
      final subscription = bluetooth
          .scan(withServices: ['180d'])
          .listen(results.add);
      await Future<void>.delayed(Duration.zero);

      expect(api.calls, ['startScan [$heartRateService]']);
      expect(bluetooth.isScanning.value, isTrue);

      events.onScanResults([scanResult('AA', name: 'Band'), scanResult('BB')]);
      await Future<void>.delayed(Duration.zero);
      expect(results.map((r) => r.device.id), ['AA', 'BB']);
      expect(results.first.name, 'Band');
      expect(results.first.device.name.value, 'Band');
      expect(results.last.device.name.value, isNull);

      await subscription.cancel();
      expect(api.calls.last, 'stopScan');
      expect(bluetooth.isScanning.value, isFalse);
    });

    test('a result and device() give the same device object', () async {
      final first = bluetooth.scan().first;
      await Future<void>.delayed(Duration.zero);
      events.onScanResults([scanResult('AA')]);

      expect(identical((await first).device, bluetooth.device('AA')), isTrue);
    });

    test('a failed start is an error on the stream', () async {
      api.startScanError = PlatformException(code: 'locationServicesOff');

      await expectLater(
        bluetooth.scan(),
        emitsInOrder([
          emitsError(isA<LocationServicesDisabledException>()),
          emitsDone,
        ]),
      );
    });

    test('stops after the timeout', () {
      fakeAsync((async) {
        var done = false;
        bluetooth
            .scan(timeout: const Duration(seconds: 5))
            .listen(null, onDone: () => done = true);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 5));

        expect(done, isTrue);
        expect(api.calls.last, 'stopScan');
      });
    });

    test(
      'the platform ending the scan closes the stream with the error',
      () async {
        final stream = bluetooth.scan();
        final expectation = expectLater(
          stream,
          emitsInOrder([
            emitsError(isA<AdapterUnavailableException>()),
            emitsDone,
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        events.onScanStopped(PlatformErrorMessage(code: 'poweredOff'));

        await expectation;
      },
    );

    test('starting a second scan ends the first', () async {
      var firstDone = false;
      bluetooth.scan().listen(null, onDone: () => firstDone = true);
      await Future<void>.delayed(Duration.zero);

      bluetooth.scan().listen(null);
      await Future<void>.delayed(Duration.zero);

      expect(firstDone, isTrue);
      expect(api.calls, ['startScan []', 'stopScan', 'startScan []']);
    });
  });

  group('BluetoothDevice', () {
    test('connect discovers services and exposes characteristics', () async {
      final device = bluetooth.device('AA');

      await device.connect();

      expect(device.isReady, isTrue);
      expect(device.services.value.single.uuid, heartRateService);
      final location = device.characteristic('180d', '2a38')!;
      expect(location.properties.read, isTrue);
      expect(await location.read(), [1]);
    });

    test('operations fail fast when not connected', () {
      final device = bluetooth.device('AA');

      expect(device.readRssi(), throwsA(isA<DeviceDisconnectedException>()));
    });

    test('values only include this characteristic', () async {
      final device = bluetooth.device('AA');
      await device.connect();
      final heartRate = device.characteristic('180d', '2a37')!;
      final values = <List<int>>[];
      heartRate.values.listen(values.add);

      CharacteristicValueMessage value(String uuid, int byte) =>
          CharacteristicValueMessage(
            characteristic: CharacteristicAddressMessage(
              deviceId: 'AA',
              serviceUuid: heartRateService,
              serviceInstance: 0,
              characteristicUuid: uuid,
              characteristicInstance: 0,
            ),
            value: Uint8List.fromList([byte]),
            timestampMicros: 0,
          );
      events.onCharacteristicValues([
        value(heartRateMeasurement, 60),
        value(bodySensorLocation, 1),
        value(heartRateMeasurement, 61),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(values, [
        [60],
        [61],
      ]);
    });

    test('notifications are turned back on after a reconnect', () {
      fakeAsync((async) {
        final device = bluetooth.device('AA');
        device.connect();
        async.flushMicrotasks();
        device.characteristic('180d', '2a37')!.setNotify(true);
        async.flushMicrotasks();
        expect(api.calls.last, 'notify 2a37 true');
        api.calls.clear();

        events.onConnectionStateChanged(
          'AA',
          ConnectionStateMessage.disconnected,
          PlatformErrorMessage(code: 'notConnected', platformCode: '8'),
        );
        async.elapse(const Duration(seconds: 1));

        expect(device.isReady, isTrue);
        expect(api.calls, ['connect AA', 'notify 2a37 true']);
        expect(device.characteristic('180d', '2a37')!.isNotifying, isTrue);
      });
    });

    test('turned-off notifications are not restored', () {
      fakeAsync((async) {
        final device = bluetooth.device('AA');
        device.connect();
        async.flushMicrotasks();
        final heartRate = device.characteristic('180d', '2a37')!;
        heartRate.setNotify(true);
        async.flushMicrotasks();
        heartRate.setNotify(false);
        async.flushMicrotasks();
        api.calls.clear();

        events.onConnectionStateChanged(
          'AA',
          ConnectionStateMessage.disconnected,
          null,
        );
        async.elapse(const Duration(seconds: 1));

        expect(api.calls, ['connect AA']);
      });
    });

    test('requestMtu updates mtu', () async {
      final device = bluetooth.device('AA');
      await device.connect();

      expect(await device.requestMtu(247), 185);
      expect(device.mtu.value, 185);
    });

    test('dispose disconnects and forgets the device', () async {
      final device = bluetooth.device('AA');
      await device.connect();

      await device.dispose();

      expect(api.calls.last, 'disconnect AA');
      expect(identical(bluetooth.device('AA'), device), isFalse);
    });
  });

  group('background mode', () {
    CharacteristicAddressMessage heartRateAddress(String deviceId) =>
        CharacteristicAddressMessage(
          deviceId: deviceId,
          serviceUuid: heartRateService,
          serviceInstance: 0,
          characteristicUuid: heartRateMeasurement,
          characteristicInstance: 0,
        );

    test('enableBackgroundMode sends the notification text', () async {
      await bluetooth.enableBackgroundMode(title: 'HR', text: 'Connected');

      expect(api.background?.title, 'HR');
      expect(api.background?.text, 'Connected');
    });

    test('a link the platform kept becomes ready with notifications on', () {
      fakeAsync((async) {
        api.sessions['AA'] = SessionMessage(
          deviceId: 'AA',
          name: 'Band',
          connected: true,
          subscribed: [heartRateAddress('AA')],
        );

        final device = bluetooth.device('AA');
        async.flushMicrotasks();

        expect(device.isReady, isTrue);
        expect(api.calls, ['connect AA', 'notify 2a37 true']);
        expect(device.characteristic('180d', '2a37')!.isNotifying, isTrue);
        expect(device.name.value, 'Band');
      });
    });

    test('a link the platform was still restoring is reconnected', () {
      fakeAsync((async) {
        api.sessions['AA'] = SessionMessage(
          deviceId: 'AA',
          connected: false,
          subscribed: [],
        );

        final device = bluetooth.device('AA');
        async.flushMicrotasks();
        expect(
          device.connectionState.value.status,
          DeviceConnectionStatus.reconnecting,
        );

        async.elapse(const Duration(seconds: 1));
        expect(device.isReady, isTrue);
      });
    });

    test('without a kept link nothing happens', () {
      fakeAsync((async) {
        final device = bluetooth.device('AA');
        async.flushMicrotasks();

        expect(api.calls, isEmpty);
        expect(
          device.connectionState.value.status,
          DeviceConnectionStatus.disconnected,
        );
      });
    });

    test('restoreDevices returns the kept devices', () async {
      api.sessions['AA'] = SessionMessage(
        deviceId: 'AA',
        connected: true,
        subscribed: [],
      );

      final devices = await bluetooth.restoreDevices();

      expect(devices.single.id, 'AA');
      expect(identical(devices.single, bluetooth.device('AA')), isTrue);
    });

    test('takeBackgroundValues converts values and times', () async {
      api.buffered.add(
        CharacteristicValueMessage(
          characteristic: heartRateAddress('AA'),
          value: Uint8List.fromList([0, 72]),
          timestampMicros: 1700000000000000,
        ),
      );

      final values = await bluetooth.takeBackgroundValues();

      expect(values.single.deviceId, 'AA');
      expect(values.single.characteristicUuid, heartRateMeasurement);
      expect(values.single.value, [0, 72]);
      expect(
        values.single.timestamp,
        DateTime.fromMicrosecondsSinceEpoch(1700000000000000),
      );
    });
  });
}
