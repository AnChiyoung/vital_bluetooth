import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/core/device_connection.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

class FakeDriver implements ConnectionDriver {
  final _linkLost = StreamController<VitalBluetoothException?>.broadcast();

  /// Answers for the next connect calls, in order. An empty queue succeeds.
  final connectResults = <Future<void> Function()>[];
  Future<void> Function() onDiscover = () async {};

  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Future<void> connect() {
    connectCalls++;
    if (connectResults.isEmpty) return Future.value();
    return connectResults.removeAt(0)();
  }

  @override
  Future<void> discoverServices() => onDiscover();

  final forgets = <bool>[];

  @override
  Future<void> disconnect({bool forget = true}) async {
    disconnectCalls++;
    forgets.add(forget);
  }

  @override
  Stream<VitalBluetoothException?> get linkLost => _linkLost.stream;

  void dropLink([VitalBluetoothException? reason]) => _linkLost.add(reason);
}

ConnectionFailedException gatt133() =>
    const ConnectionFailedException('AA', platformCode: '133');

void main() {
  late FakeDriver driver;

  setUp(() => driver = FakeDriver());

  DeviceConnection create([
    ConnectionOptions options = const ConnectionOptions(),
  ]) => DeviceConnection('AA', driver, options: options);

  List<DeviceConnectionStatus> record(DeviceConnection connection) {
    final statuses = <DeviceConnectionStatus>[];
    connection.stateStream.listen((s) => statuses.add(s.status));
    return statuses;
  }

  test('connect goes through connecting and discovering to ready', () {
    fakeAsync((async) {
      final connection = create();
      final statuses = record(connection);
      var done = false;

      connection.connect().then((_) => done = true);
      async.flushMicrotasks();

      expect(done, isTrue);
      expect(connection.value.isReady, isTrue);
      expect(statuses, [
        DeviceConnectionStatus.connecting,
        DeviceConnectionStatus.discovering,
        DeviceConnectionStatus.ready,
      ]);
    });
  });

  test('the ValueListenable notifies listeners', () {
    fakeAsync((async) {
      final connection = create();
      var notifications = 0;
      connection.state.addListener(() => notifications++);

      connection.connect();
      async.flushMicrotasks();

      expect(notifications, 3);
      expect(connection.state.value.isReady, isTrue);
    });
  });

  test('concurrent connect calls share one attempt', () {
    fakeAsync((async) {
      final connection = create();
      final gate = Completer<void>();
      driver.connectResults.add(() => gate.future);

      final first = connection.connect();
      final second = connection.connect();
      gate.complete();
      async.flushMicrotasks();

      expect(driver.connectCalls, 1);
      expect(identical(first, second), isTrue);
    });
  });

  test('run fails fast when the device is not ready', () {
    fakeAsync((async) {
      final connection = create();
      Object? error;

      connection.run(BluetoothOperation.read, () async => 1).catchError((
        Object e,
      ) {
        error = e;
        return 0;
      });
      async.flushMicrotasks();

      expect(error, isA<DeviceDisconnectedException>());
    });
  });

  test('run executes once ready', () {
    fakeAsync((async) {
      final connection = create();
      int? result;

      connection.connect();
      async.flushMicrotasks();
      connection.run(BluetoothOperation.read, () async => 42).then((v) {
        result = v;
      });
      async.flushMicrotasks();

      expect(result, 42);
    });
  });

  test('retries retryable connect failures and releases between tries', () {
    fakeAsync((async) {
      final connection = create();
      driver.connectResults
        ..add(() => Future.error(gatt133()))
        ..add(() => Future.error(gatt133()));
      var done = false;

      connection.connect().then((_) => done = true);
      async.flushMicrotasks();
      expect(driver.connectCalls, 1);
      expect(driver.disconnectCalls, 1);
      // Between tries the device stays wanted.
      expect(driver.forgets, [false]);

      async.elapse(const Duration(milliseconds: 500));
      expect(driver.connectCalls, 2);

      async.elapse(const Duration(milliseconds: 500));
      expect(driver.connectCalls, 3);
      expect(done, isTrue);
      expect(connection.value.isReady, isTrue);
    });
  });

  test('gives up after connectAttempts and reports the last error', () {
    fakeAsync((async) {
      final connection = create(const ConnectionOptions(connectAttempts: 2));
      driver.connectResults
        ..add(() => Future.error(gatt133()))
        ..add(() => Future.error(gatt133()));
      Object? error;

      connection.connect().catchError((Object e) => error = e);
      async.elapse(const Duration(seconds: 1));

      expect(driver.connectCalls, 2);
      expect(error, isA<ConnectionFailedException>());
      expect(connection.value.status, DeviceConnectionStatus.disconnected);
      expect(connection.value.error, isA<ConnectionFailedException>());
      // Each failed try is released; giving up forgets the device.
      expect(driver.forgets, [false, false, true]);
    });
  });

  test('does not retry a non-retryable failure', () {
    fakeAsync((async) {
      final connection = create();
      driver.connectResults.add(
        () => Future.error(
          const ConnectionFailedException('AA', retryable: false),
        ),
      );
      Object? error;

      connection.connect().catchError((Object e) => error = e);
      async.elapse(const Duration(seconds: 5));

      expect(driver.connectCalls, 1);
      expect(error, isA<ConnectionFailedException>());
    });
  });

  test('a connect that never answers times out', () {
    fakeAsync((async) {
      final connection = create(
        const ConnectionOptions(
          connectAttempts: 1,
          connectTimeout: Duration(seconds: 3),
        ),
      );
      driver.connectResults.add(() => Completer<void>().future);
      Object? error;

      connection.connect().catchError((Object e) => error = e);
      async.elapse(const Duration(seconds: 3));

      expect(
        error,
        isA<OperationTimeoutException>().having(
          (e) => e.operation,
          'operation',
          BluetoothOperation.connect,
        ),
      );
      // The attempt is released, then the device is forgotten.
      expect(driver.forgets, [false, true]);
    });
  });

  test('unknown driver errors are wrapped', () {
    fakeAsync((async) {
      final connection = create(const ConnectionOptions(connectAttempts: 1));
      driver.connectResults.add(() => Future.error(StateError('boom')));
      Object? error;

      connection.connect().catchError((Object e) => error = e);
      async.flushMicrotasks();

      expect(error, isA<UnknownBluetoothException>());
    });
  });

  test('disconnect during connect cancels it at once', () {
    fakeAsync((async) {
      final connection = create();
      final gate = Completer<void>();
      driver.connectResults.add(() => gate.future);
      Object? error;

      connection.connect().catchError((Object e) => error = e);
      async.flushMicrotasks();
      connection.disconnect();
      async.flushMicrotasks();

      expect(error, isA<OperationCancelledException>());
      expect(connection.value.status, DeviceConnectionStatus.disconnected);

      // The platform answering late must not bring the device back.
      gate.complete();
      async.elapse(const Duration(seconds: 1));
      expect(connection.value.status, DeviceConnectionStatus.disconnected);
    });
  });

  group('when the link drops', () {
    test('fails queued operations and reconnects with backoff', () {
      fakeAsync((async) {
        final connection = create(
          const ConnectionOptions(
            reconnect: ReconnectPolicy(initialDelay: Duration(seconds: 1)),
          ),
        );
        connection.connect();
        async.flushMicrotasks();

        Object? opError;
        connection
            .run(BluetoothOperation.read, () => Completer<int>().future)
            .catchError((Object e) {
              opError = e;
              return 0;
            });
        async.flushMicrotasks();

        driver.connectResults.add(() => Future.error(gatt133()));
        driver.dropLink();
        async.flushMicrotasks();

        expect(opError, isA<DeviceDisconnectedException>());
        expect(connection.value.status, DeviceConnectionStatus.reconnecting);
        expect(connection.value.reconnectAttempt, 1);

        async.elapse(const Duration(seconds: 1));
        expect(driver.connectCalls, 2);
        expect(connection.value.reconnectAttempt, 2);

        async.elapse(const Duration(seconds: 1));
        expect(driver.connectCalls, 2, reason: 'second wait is 2s');

        async.elapse(const Duration(seconds: 1));
        expect(driver.connectCalls, 3);
        expect(connection.value.isReady, isTrue);
        expect(connection.value.reconnectAttempt, 0);
      });
    });

    test('gives up after maxAttempts', () {
      fakeAsync((async) {
        final connection = create(
          const ConnectionOptions(
            reconnect: ReconnectPolicy(
              maxAttempts: 2,
              initialDelay: Duration(seconds: 1),
            ),
          ),
        );
        connection.connect();
        async.flushMicrotasks();

        driver.connectResults
          ..add(() => Future.error(gatt133()))
          ..add(() => Future.error(gatt133()));
        driver.dropLink();
        async.elapse(const Duration(seconds: 10));

        expect(driver.connectCalls, 3);
        expect(connection.value.status, DeviceConnectionStatus.disconnected);
        expect(connection.value.error, isA<ConnectionFailedException>());
        expect(driver.forgets, [false, false, true]);
      });
    });

    test('with ReconnectPolicy.none goes straight to disconnected', () {
      fakeAsync((async) {
        final connection = create(
          const ConnectionOptions(reconnect: ReconnectPolicy.none()),
        );
        connection.connect();
        async.flushMicrotasks();

        driver.dropLink(const DeviceDisconnectedException('AA'));
        async.elapse(const Duration(seconds: 10));

        expect(driver.connectCalls, 1);
        expect(connection.value.status, DeviceConnectionStatus.disconnected);
        expect(connection.value.error, isA<DeviceDisconnectedException>());
      });
    });

    test('disconnect during backoff stops reconnecting', () {
      fakeAsync((async) {
        final connection = create();
        connection.connect();
        async.flushMicrotasks();

        driver.dropLink();
        async.flushMicrotasks();
        connection.disconnect();
        async.elapse(const Duration(minutes: 1));

        expect(driver.connectCalls, 1);
        expect(connection.value.status, DeviceConnectionStatus.disconnected);
      });
    });

    test('connect during backoff tries at once', () {
      fakeAsync((async) {
        final connection = create(
          const ConnectionOptions(
            reconnect: ReconnectPolicy(initialDelay: Duration(seconds: 30)),
          ),
        );
        connection.connect();
        async.flushMicrotasks();

        driver.dropLink();
        async.flushMicrotasks();
        connection.connect();
        async.flushMicrotasks();

        expect(driver.connectCalls, 2);
        expect(connection.value.isReady, isTrue);

        async.elapse(const Duration(minutes: 1));
        expect(driver.connectCalls, 2, reason: 'old backoff must not fire');
      });
    });

    test('is ignored after an explicit disconnect', () {
      fakeAsync((async) {
        final connection = create();
        connection.connect();
        async.flushMicrotasks();
        connection.disconnect();
        async.flushMicrotasks();

        driver.dropLink();
        async.elapse(const Duration(minutes: 1));

        expect(driver.connectCalls, 1);
        expect(connection.value.status, DeviceConnectionStatus.disconnected);
      });
    });
  });

  test('dispose disconnects and closes the state stream', () {
    fakeAsync((async) {
      final connection = create();
      var streamClosed = false;
      connection.stateStream.listen(null, onDone: () => streamClosed = true);
      connection.connect();
      async.flushMicrotasks();

      connection.dispose();
      async.flushMicrotasks();

      expect(driver.disconnectCalls, 1);
      expect(streamClosed, isTrue);
      expect(connection.connect, throwsStateError);
    });
  });
}
