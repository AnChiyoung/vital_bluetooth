import 'dart:async';

import 'package:flutter/foundation.dart';

import 'connection_options.dart';
import 'connection_state.dart';
import 'errors.dart';
import 'operation.dart';
import 'operation_queue.dart';

/// The platform side of one device's link, implemented per platform and
/// transport (BLE or Classic).
///
/// Every future completes only once the platform has confirmed the result,
/// for example after Android's `onConnectionStateChange` callback. This keeps
/// the platform code free of its own state tracking: [DeviceConnection] does
/// all of that.
abstract interface class ConnectionDriver {
  /// Opens the link. Fails if the platform reports an error or the link
  /// drops before it is up.
  Future<void> connect();

  /// Discovers services. Classic transports can complete immediately.
  Future<void> discoverServices();

  /// Closes the link and releases every native resource for it, such as
  /// Android's `BluetoothGatt.close()`. Must be safe to call in any state.
  Future<void> disconnect();

  /// Emits when an established link drops without [disconnect] being called,
  /// with the reason if the platform gave one.
  Stream<VitalBluetoothException?> get linkLost;
}

/// Owns the connection lifecycle of one device.
///
/// It retries failed connects, restores dropped links according to a
/// [ReconnectPolicy], and sends every operation through an
/// [OperationQueue] so the platform only ever sees one request at a time.
///
/// The current state is available synchronously through [state] (a
/// [ValueListenable]) and as a [stateStream], so it plugs into Provider,
/// Riverpod or GetX without extra adapters.
class DeviceConnection {
  DeviceConnection(
    this.deviceId,
    this._driver, {
    this.options = const ConnectionOptions(),
  }) : _queue = OperationQueue(
         deviceId,
         defaultTimeout: options.operationTimeout,
       ) {
    _linkLostSubscription = _driver.linkLost.listen(_onLinkLost);
  }

  final String deviceId;
  final ConnectionOptions options;
  final ConnectionDriver _driver;
  final OperationQueue _queue;
  final ValueNotifier<DeviceConnectionState> _state = ValueNotifier(
    DeviceConnectionState.disconnected,
  );
  final StreamController<DeviceConnectionState> _stateController =
      StreamController.broadcast();
  late final StreamSubscription<VitalBluetoothException?> _linkLostSubscription;

  /// Bumped by every connect, reconnect and disconnect. A flow that sees a
  /// different value after an await has been superseded and must stop.
  int _generation = 0;
  Completer<void>? _pendingConnect;
  bool _disposed = false;

  ValueListenable<DeviceConnectionState> get state => _state;

  DeviceConnectionState get value => _state.value;

  /// Emits every state change. It does not replay the current state; read
  /// [value] first if you need it.
  Stream<DeviceConnectionState> get stateStream => _stateController.stream;

  /// Connects and discovers services, retrying retryable failures up to
  /// [ConnectionOptions.connectAttempts] times.
  ///
  /// Calls made while a connect is already running share its result. A call
  /// made while reconnecting skips the remaining backoff and tries at once.
  Future<void> connect() {
    _checkNotDisposed();
    if (value.isReady) return Future.value();
    final pending = _pendingConnect;
    if (pending != null) return pending.future;

    final completer = _pendingConnect = Completer<void>();
    _connectFlow()
        .then(
          (_) {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
        )
        .whenComplete(() {
          if (identical(_pendingConnect, completer)) _pendingConnect = null;
        });
    return completer.future;
  }

  /// Closes the link and stops any connect or reconnect in progress.
  ///
  /// A pending [connect] fails with an [OperationCancelledException] and
  /// queued operations fail the same way.
  Future<void> disconnect() async {
    if (_disposed) return;
    _generation++;
    _queue.cancelAll();
    _pendingConnect?.completeError(
      OperationCancelledException(deviceId, BluetoothOperation.connect),
    );
    _pendingConnect = null;
    if (value.status == DeviceConnectionStatus.disconnected) return;

    _emit(const DeviceConnectionState(DeviceConnectionStatus.disconnecting));
    await _releaseQuietly();
    _emit(DeviceConnectionState.disconnected);
  }

  /// Runs [task] through the operation queue once the device is ready.
  ///
  /// Fails at once with a [DeviceDisconnectedException] when it is not.
  Future<T> run<T>(
    BluetoothOperation operation,
    Future<T> Function() task, {
    Duration? timeout,
  }) {
    if (_disposed || !value.isReady) {
      return Future.error(
        DeviceDisconnectedException(deviceId, operation: operation),
      );
    }
    return _queue.enqueue(operation, task, timeout: timeout);
  }

  /// Disconnects and releases everything. The object cannot be used again.
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    _queue.dispose();
    // Not awaited: a broadcast subscription returns a future bound to the
    // root zone, and nothing here depends on the cancel having finished.
    unawaited(_linkLostSubscription.cancel());
    await _stateController.close();
    _state.dispose();
  }

  Future<void> _connectFlow() async {
    final generation = ++_generation;
    VitalBluetoothException? lastError;
    for (var attempt = 1; attempt <= options.connectAttempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(options.connectRetryDelay);
        _ensureCurrent(generation, BluetoothOperation.connect);
      }
      try {
        await _establish(generation, DeviceConnectionStatus.connecting);
        return;
      } on OperationCancelledException {
        rethrow;
      } on VitalBluetoothException catch (e) {
        lastError = e;
        if (!e.isRetryable) break;
      }
    }
    if (generation == _generation) {
      _emit(
        DeviceConnectionState(
          DeviceConnectionStatus.disconnected,
          error: lastError,
        ),
      );
    }
    throw lastError!;
  }

  Future<void> _reconnectFlow(VitalBluetoothException cause) async {
    final generation = ++_generation;
    var lastError = cause;
    for (var attempt = 1; ; attempt++) {
      final delay = options.reconnect.delayFor(attempt);
      if (delay == null) break;
      _emit(
        DeviceConnectionState(
          DeviceConnectionStatus.reconnecting,
          error: lastError,
          reconnectAttempt: attempt,
        ),
      );
      await Future<void>.delayed(delay);
      if (generation != _generation || _disposed) return;
      try {
        await _establish(
          generation,
          DeviceConnectionStatus.reconnecting,
          attempt: attempt,
        );
        return;
      } on OperationCancelledException {
        return;
      } on VitalBluetoothException catch (e) {
        if (generation != _generation) return;
        lastError = e;
        if (!e.isRetryable) break;
      }
    }
    if (generation == _generation) {
      _emit(
        DeviceConnectionState(
          DeviceConnectionStatus.disconnected,
          error: lastError,
        ),
      );
    }
  }

  /// One connect and discover pass. On failure the native side is released
  /// so the next attempt starts clean, which avoids Android's repeated
  /// status 133 after a failed connect.
  Future<void> _establish(
    int generation,
    DeviceConnectionStatus connectingStatus, {
    int attempt = 0,
  }) async {
    _emit(DeviceConnectionState(connectingStatus, reconnectAttempt: attempt));
    try {
      await _step(
        BluetoothOperation.connect,
        _driver.connect,
        options.connectTimeout,
      );
      _ensureCurrent(generation, BluetoothOperation.connect);
      _emit(
        DeviceConnectionState(
          DeviceConnectionStatus.discovering,
          reconnectAttempt: attempt,
        ),
      );
      await _step(
        BluetoothOperation.discoverServices,
        _driver.discoverServices,
        options.discoverTimeout,
      );
      _ensureCurrent(generation, BluetoothOperation.discoverServices);
      _emit(const DeviceConnectionState(DeviceConnectionStatus.ready));
    } on VitalBluetoothException {
      if (generation == _generation) await _releaseQuietly();
      rethrow;
    }
  }

  Future<void> _step(
    BluetoothOperation operation,
    Future<void> Function() action,
    Duration timeout,
  ) async {
    try {
      await action().timeout(timeout);
    } on TimeoutException {
      throw OperationTimeoutException(deviceId, operation, timeout);
    } on VitalBluetoothException {
      rethrow;
    } catch (e) {
      throw UnknownBluetoothException('${operation.name} failed: $e');
    }
  }

  void _onLinkLost(VitalBluetoothException? reason) {
    if (_disposed || value.status != DeviceConnectionStatus.ready) {
      // While connecting the driver's own futures report the failure, and
      // while disconnecting the drop is expected.
      return;
    }
    _queue.cancelAll(disconnected: true);
    final cause = reason ?? DeviceDisconnectedException(deviceId);
    if (options.reconnect.delayFor(1) == null) {
      _generation++;
      _emit(
        DeviceConnectionState(
          DeviceConnectionStatus.disconnected,
          error: cause,
        ),
      );
      unawaited(_releaseQuietly());
      return;
    }
    unawaited(_reconnectFlow(cause));
  }

  Future<void> _releaseQuietly() async {
    try {
      await _driver.disconnect().timeout(options.disconnectTimeout);
    } catch (_) {
      // Releasing is best effort; the link is treated as closed either way.
    }
  }

  void _ensureCurrent(int generation, BluetoothOperation operation) {
    if (generation != _generation || _disposed) {
      throw OperationCancelledException(deviceId, operation);
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('DeviceConnection for $deviceId was disposed');
    }
  }

  void _emit(DeviceConnectionState next) {
    if (_disposed || _state.value == next) return;
    _state.value = next;
    _stateController.add(next);
  }
}
