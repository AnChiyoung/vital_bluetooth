import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How to restore a link that dropped on its own.
///
/// Waits [initialDelay] before the first attempt and multiplies the wait by
/// [multiplier] after every failure, up to [maxDelay].
@immutable
class ReconnectPolicy {
  const ReconnectPolicy({
    this.maxAttempts = 5,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
  }) : assert(maxAttempts == null || maxAttempts >= 0),
       assert(multiplier >= 1.0);

  /// Keeps trying until the caller disconnects explicitly. Suited to
  /// wearables that should stay connected all day.
  const ReconnectPolicy.unlimited({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
  }) : maxAttempts = null;

  /// Never reconnects. A dropped link goes straight to disconnected.
  const ReconnectPolicy.none()
    : maxAttempts = 0,
      initialDelay = Duration.zero,
      maxDelay = Duration.zero,
      multiplier = 1.0;

  /// Null means no limit.
  final int? maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  /// The wait before reconnect [attempt] (starting at 1), or null when the
  /// policy gives up.
  Duration? delayFor(int attempt) {
    final max = maxAttempts;
    if (attempt < 1 || (max != null && attempt > max)) return null;
    final millis =
        initialDelay.inMilliseconds * math.pow(multiplier, attempt - 1);
    return Duration(
      milliseconds: math.min(millis, maxDelay.inMilliseconds).round(),
    );
  }
}

/// Time limits and retry rules for one device connection.
@immutable
class ConnectionOptions {
  const ConnectionOptions({
    this.connectTimeout = const Duration(seconds: 15),
    this.discoverTimeout = const Duration(seconds: 15),
    this.disconnectTimeout = const Duration(seconds: 5),
    this.operationTimeout = const Duration(seconds: 10),
    this.connectAttempts = 3,
    this.connectRetryDelay = const Duration(milliseconds: 500),
    this.reconnect = const ReconnectPolicy(),
  }) : assert(connectAttempts >= 1);

  final Duration connectTimeout;
  final Duration discoverTimeout;
  final Duration disconnectTimeout;

  /// Default limit for each read, write or other queued operation.
  final Duration operationTimeout;

  /// How many times an explicit connect is tried when it fails with a
  /// retryable error, such as Android GATT status 133.
  final int connectAttempts;

  /// The wait between those tries.
  final Duration connectRetryDelay;

  /// What to do when an established link drops.
  final ReconnectPolicy reconnect;
}
