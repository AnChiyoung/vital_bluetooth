import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/platform/messages.g.dart';
import 'package:vital_bluetooth/src/platform/platform_events.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BleEvents', () {
    late BleEvents events;

    setUp(() => events = BleEvents());

    test('republishes connection state changes', () async {
      final next = events.connectionStates.first;

      events.onConnectionStateChanged(
        'AA',
        ConnectionStateMessage.disconnected,
        PlatformErrorMessage(code: 'notConnected', platformCode: '8'),
      );

      final event = await next;
      expect(event.deviceId, 'AA');
      expect(event.state, ConnectionStateMessage.disconnected);
      expect(event.error?.platformCode, '8');
    });

    test('keeps notification batches together', () async {
      final next = events.characteristicValues.first;
      final address = CharacteristicAddressMessage(
        deviceId: 'AA',
        serviceUuid: 's',
        serviceInstance: 0,
        characteristicUuid: 'c',
        characteristicInstance: 0,
      );

      events.onCharacteristicValues([
        CharacteristicValueMessage(
          characteristic: address,
          value: Uint8List.fromList([1]),
          timestampMicros: 1,
        ),
        CharacteristicValueMessage(
          characteristic: address,
          value: Uint8List.fromList([2]),
          timestampMicros: 2,
        ),
      ]);

      expect((await next).map((v) => v.value.first), [1, 2]);
    });

    test('receives messages sent over the channel after attach', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      events.attach();
      final next = events.mtuChanged.first;

      await messenger.handlePlatformMessage(
        'dev.flutter.pigeon.vital_bluetooth.BleFlutterApi.onMtuChanged',
        BleFlutterApi.pigeonChannelCodec.encodeMessage(<Object?>['AA', 247]),
        (_) {},
      );

      expect(await next, (deviceId: 'AA', mtu: 247));
      await events.dispose();
    });

    test('dispose closes the streams', () async {
      final done = Completer<void>();
      events.adapterState.listen(null, onDone: done.complete);

      await events.dispose();

      expect(done.isCompleted, isTrue);
    });
  });

  test('ClassicEvents republishes received data', () async {
    final events = ClassicEvents();
    final next = events.data.first;

    events.onData('AA', Uint8List.fromList([0x41]));

    final event = await next;
    expect(event.deviceId, 'AA');
    expect(event.data, [0x41]);
  });
}
