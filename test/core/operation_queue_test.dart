import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vital_bluetooth/src/core/operation_queue.dart';
import 'package:vital_bluetooth/vital_bluetooth.dart';

void main() {
  const read = BluetoothOperation.read;
  const write = BluetoothOperation.write;

  test('runs one operation at a time in order', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      final started = <String>[];
      final first = Completer<int>();
      final second = Completer<int>();
      final results = <int>[];

      queue
          .enqueue(read, () {
            started.add('first');
            return first.future;
          })
          .then(results.add);
      queue
          .enqueue(write, () {
            started.add('second');
            return second.future;
          })
          .then(results.add);
      async.flushMicrotasks();

      expect(started, ['first']);
      expect(queue.isBusy, isTrue);
      expect(queue.pendingCount, 1);

      first.complete(1);
      async.flushMicrotasks();
      expect(started, ['first', 'second']);

      second.complete(2);
      async.flushMicrotasks();
      expect(results, [1, 2]);
      expect(queue.isBusy, isFalse);
    });
  });

  test('keeps going after an operation fails or throws synchronously', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      Object? asyncError;
      Object? syncError;
      int? result;

      queue
          .enqueue<int>(read, () => Future.error(StateError('async')))
          .catchError((Object e) {
            asyncError = e;
            return 0;
          });
      queue.enqueue<int>(read, () => throw StateError('sync')).catchError((
        Object e,
      ) {
        syncError = e;
        return 0;
      });
      queue.enqueue(write, () async => 3).then((v) => result = v);
      async.flushMicrotasks();

      expect(asyncError, isA<StateError>());
      expect(syncError, isA<StateError>());
      expect(result, 3);
    });
  });

  test('times out a stuck operation and starts the next one', () {
    fakeAsync((async) {
      final queue = OperationQueue(
        'AA',
        defaultTimeout: const Duration(seconds: 5),
      );
      final stuck = Completer<int>();
      Object? error;
      var nextStarted = false;

      queue.enqueue(read, () => stuck.future).catchError((Object e) {
        error = e;
        return 0;
      });
      queue.enqueue(write, () async {
        nextStarted = true;
      });

      async.elapse(const Duration(seconds: 4));
      expect(error, isNull);
      expect(nextStarted, isFalse);

      async.elapse(const Duration(seconds: 1));
      expect(
        error,
        isA<OperationTimeoutException>()
            .having((e) => e.operation, 'operation', read)
            .having((e) => e.timeout, 'timeout', const Duration(seconds: 5)),
      );
      expect(nextStarted, isTrue);

      // A late answer from the platform must not throw or change anything.
      stuck.complete(1);
      async.flushMicrotasks();
    });
  });

  test('a per-call timeout overrides the default', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      Object? error;

      queue
          .enqueue(
            read,
            () => Completer<int>().future,
            timeout: const Duration(milliseconds: 300),
          )
          .catchError((Object e) {
            error = e;
            return 0;
          });

      async.elapse(const Duration(milliseconds: 300));
      expect(error, isA<OperationTimeoutException>());
    });
  });

  test('cancelAll fails the running and the waiting operations', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      final errors = <Object>[];

      for (final op in [read, write]) {
        queue.enqueue(op, () => Completer<int>().future).catchError((Object e) {
          errors.add(e);
          return 0;
        });
      }
      async.flushMicrotasks();

      queue.cancelAll();
      async.flushMicrotasks();

      expect(errors, [
        isA<OperationCancelledException>().having(
          (e) => e.operation,
          'operation',
          read,
        ),
        isA<OperationCancelledException>().having(
          (e) => e.operation,
          'operation',
          write,
        ),
      ]);
      expect(queue.isBusy, isFalse);
      expect(queue.pendingCount, 0);
    });
  });

  test('cancelAll with disconnected reports a dropped link', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      Object? error;

      queue.enqueue(read, () => Completer<int>().future).catchError((Object e) {
        error = e;
        return 0;
      });
      async.flushMicrotasks();

      queue.cancelAll(disconnected: true);
      async.flushMicrotasks();

      expect(
        error,
        isA<DeviceDisconnectedException>()
            .having((e) => e.operation, 'operation', read)
            .having((e) => e.isRetryable, 'isRetryable', isTrue),
      );
    });
  });

  test('accepts new work after cancelAll', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      int? result;

      queue.enqueue(read, () => Completer<int>().future).ignore();
      async.flushMicrotasks();
      queue.cancelAll();

      queue.enqueue(write, () async => 7).then((v) => result = v);
      async.flushMicrotasks();

      expect(result, 7);
    });
  });

  test('a dropped future does not leak an uncaught error', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');

      queue.enqueue(read, () => Completer<int>().future);
      async.flushMicrotasks();
      queue.cancelAll();
      async.flushMicrotasks();
    });
  });

  test('dispose cancels everything and rejects new operations', () {
    fakeAsync((async) {
      final queue = OperationQueue('AA');
      Object? pendingError;
      Object? lateError;
      var lateTaskCalled = false;

      queue.enqueue(read, () => Completer<int>().future).catchError((Object e) {
        pendingError = e;
        return 0;
      });
      async.flushMicrotasks();

      queue.dispose();
      queue
          .enqueue(write, () async {
            lateTaskCalled = true;
          })
          .catchError((Object e) {
            lateError = e;
          });
      async.flushMicrotasks();

      expect(queue.isDisposed, isTrue);
      expect(pendingError, isA<OperationCancelledException>());
      expect(lateError, isA<OperationCancelledException>());
      expect(lateTaskCalled, isFalse);
    });
  });
}
