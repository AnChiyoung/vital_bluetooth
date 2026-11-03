import 'package:flutter/foundation.dart';

import 'errors.dart';

/// Where a device is in its connection lifecycle.
enum DeviceConnectionStatus {
  disconnected,

  /// Opening the link after an explicit connect call.
  connecting,

  /// The link is up and services are being discovered.
  discovering,

  /// Connected, discovered and ready for reads, writes and notifications.
  ready,

  /// The link dropped and the reconnect policy is trying to restore it.
  reconnecting,

  /// Closing the link after an explicit disconnect call.
  disconnecting,
}

/// An immutable snapshot of a device's connection.
///
/// Named with a `Device` prefix so it does not clash with Flutter's own
/// `ConnectionState` from `package:flutter/widgets.dart`.
@immutable
class DeviceConnectionState {
  const DeviceConnectionState(
    this.status, {
    this.error,
    this.reconnectAttempt = 0,
  });

  static const disconnected = DeviceConnectionState(
    DeviceConnectionStatus.disconnected,
  );

  final DeviceConnectionStatus status;

  /// Why the device ended up in this state, such as the error that made a
  /// connect fail or the link drop. Null after a clean connect or disconnect.
  final VitalBluetoothException? error;

  /// The current reconnect attempt, starting at 1. Zero when not
  /// reconnecting.
  final int reconnectAttempt;

  bool get isReady => status == DeviceConnectionStatus.ready;

  @override
  bool operator ==(Object other) =>
      other is DeviceConnectionState &&
      other.status == status &&
      other.error == error &&
      other.reconnectAttempt == reconnectAttempt;

  @override
  int get hashCode => Object.hash(status, error, reconnectAttempt);

  @override
  String toString() {
    final buffer = StringBuffer('DeviceConnectionState(${status.name}');
    if (reconnectAttempt > 0) buffer.write(', attempt: $reconnectAttempt');
    if (error != null) buffer.write(', error: $error');
    buffer.write(')');
    return buffer.toString();
  }
}
