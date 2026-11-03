import 'dart:async';
import 'dart:collection';

import 'errors.dart';
import 'operation.dart';

/// Runs the operations for one device strictly one at a time.
///
/// Android's GATT layer silently drops a request sent while another one is
/// still in flight, so every request to a device goes through this queue on
/// every platform. Each operation has a time limit; when it expires the
/// caller gets an [OperationTimeoutException] and the queue moves on.
class OperationQueue {
  OperationQueue(
    this.deviceId, {
    this.defaultTimeout = const Duration(seconds: 10),
  });

  final String deviceId;

  /// The time limit used when [enqueue] is called without one.
  final Duration defaultTimeout;

  final Queue<_Entry<dynamic>> _pending = Queue();
  _Entry<dynamic>? _running;
  bool _disposed = false;

  /// Number of operations waiting behind the running one.
  int get pendingCount => _pending.length;

  /// Whether an operation is running right now.
  bool get isBusy => _running != null;

  bool get isDisposed => _disposed;

  /// Adds [task] to the end of the queue and completes with its result.
  ///
  /// [task] is not called until every operation enqueued before it has
  /// finished, failed, timed out or been cancelled.
  Future<T> enqueue<T>(
    BluetoothOperation operation,
    Future<T> Function() task, {
    Duration? timeout,
  }) {
    if (_disposed) {
      return Future.error(
        OperationCancelledException(
          deviceId,
          operation,
          message:
              '${operation.name} on $deviceId was rejected: '
              'the queue is disposed',
        ),
      );
    }
    final entry = _Entry<T>(operation, task, timeout ?? defaultTimeout);
    _pending.add(entry);
    _runNext();
    return entry.completer.future;
  }

  /// Fails the running operation and everything waiting behind it.
  ///
  /// With [disconnected] the callers get a [DeviceDisconnectedException],
  /// otherwise an [OperationCancelledException]. A result that arrives later
  /// from the platform for the running operation is ignored.
  void cancelAll({bool disconnected = false}) {
    final entries = [?_running, ..._pending];
    _pending.clear();
    for (final entry in entries) {
      entry.fail(
        disconnected
            ? DeviceDisconnectedException(deviceId, operation: entry.operation)
            : OperationCancelledException(deviceId, entry.operation),
      );
    }
  }

  /// Cancels everything and rejects any further [enqueue] calls.
  void dispose() {
    _disposed = true;
    cancelAll();
  }

  void _runNext() {
    if (_running != null || _pending.isEmpty) return;
    final entry = _pending.removeFirst();
    _running = entry;
    entry.run(deviceId).whenComplete(() {
      if (identical(_running, entry)) _running = null;
      _runNext();
    });
  }
}

class _Entry<T> {
  _Entry(this.operation, this.task, this.timeout);

  final BluetoothOperation operation;
  final Future<T> Function() task;
  final Duration timeout;
  final Completer<T> completer = Completer<T>();
  Timer? _timer;

  /// Starts [task] and completes once the entry has settled in any way.
  Future<void> run(String deviceId) {
    _timer = Timer(
      timeout,
      () => fail(OperationTimeoutException(deviceId, operation, timeout)),
    );
    Future<T>.sync(task).then(_succeed, onError: fail);
    // Listening here also marks the error as handled when the caller dropped
    // the future, so a cancelled operation never surfaces as uncaught.
    return completer.future.then<void>((_) {}, onError: (_) {});
  }

  void _succeed(T value) {
    if (completer.isCompleted) return;
    _timer?.cancel();
    completer.complete(value);
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (completer.isCompleted) return;
    _timer?.cancel();
    completer.completeError(error, stackTrace);
  }
}
