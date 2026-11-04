import 'operation.dart';

/// Base type for every error thrown by vital_bluetooth.
///
/// The hierarchy is sealed, so a `switch` over it is checked for
/// exhaustiveness. Native error codes are kept in [platformCode] for logging,
/// but callers should branch on the subtype, which means the same thing on
/// every platform.
sealed class VitalBluetoothException implements Exception {
  const VitalBluetoothException(
    this.message, {
    this.platformCode,
    this.platformMessage,
  });

  /// A human readable description in English.
  final String message;

  /// The raw native code, such as Android GATT status 133, if there was one.
  final String? platformCode;

  /// The raw native message, if there was one.
  final String? platformMessage;

  /// Whether trying the same thing again may succeed without user action.
  bool get isRetryable => false;

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message');
    if (platformCode != null) buffer.write(' (platformCode: $platformCode)');
    if (platformMessage != null) buffer.write(' - $platformMessage');
    return buffer.toString();
  }
}

/// Why the Bluetooth adapter cannot be used.
enum AdapterUnavailableReason {
  /// The device has no Bluetooth hardware or the platform lacks the feature.
  unsupported,

  /// Bluetooth is turned off.
  poweredOff,

  /// The adapter is turning on or off, or the platform has not reported yet.
  transitioning,
}

/// The Bluetooth adapter is missing, off or not ready.
final class AdapterUnavailableException extends VitalBluetoothException {
  AdapterUnavailableException(
    this.reason, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(message ?? 'Bluetooth adapter is unavailable: ${reason.name}');

  final AdapterUnavailableReason reason;

  @override
  bool get isRetryable => reason == AdapterUnavailableReason.transitioning;
}

/// The user or the system has not granted a required Bluetooth permission.
final class PermissionDeniedException extends VitalBluetoothException {
  PermissionDeniedException(
    this.permissions, {
    this.permanentlyDenied = false,
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(message ?? 'Bluetooth permission denied: $permissions');

  /// Platform names of the missing permissions, such as
  /// `android.permission.BLUETOOTH_SCAN`.
  final List<String> permissions;

  /// True when the system will no longer show a prompt and the user has to
  /// change it in the system settings.
  final bool permanentlyDenied;
}

/// Location services are off, so Android 7 to 11 returns no scan results.
///
/// Those Android versions only deliver BLE scan results while the phone's
/// location setting is on, even with the permission granted. Ask the user
/// to turn it on. Android 12 and newer don't need it.
final class LocationServicesDisabledException extends VitalBluetoothException {
  const LocationServicesDisabledException({
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(
         message ??
             'Location services are off; Android needs them on to scan for '
                 'Bluetooth devices',
       );
}

/// The requested feature is not available on this platform or device.
///
/// For example Bluetooth Classic on iOS, or 2M PHY on old Android hardware.
final class FeatureNotSupportedException extends VitalBluetoothException {
  const FeatureNotSupportedException(
    this.feature, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(message ?? 'Feature not supported on this platform: $feature');

  final String feature;
}

/// Base type for errors tied to one remote device.
sealed class DeviceException extends VitalBluetoothException {
  const DeviceException(
    this.deviceId,
    super.message, {
    super.platformCode,
    super.platformMessage,
  });

  /// The platform identifier of the remote device.
  ///
  /// A MAC address on Android and Windows, a UUID on iOS and macOS.
  final String deviceId;
}

/// No device with [deviceId] is known to the platform.
final class DeviceNotFoundException extends DeviceException {
  const DeviceNotFoundException(
    String deviceId, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(deviceId, message ?? 'Device not found: $deviceId');
}

/// Establishing a connection failed.
///
/// On Android this covers GATT status 133 and similar transient failures,
/// which usually succeed when retried after a short delay.
final class ConnectionFailedException extends DeviceException {
  const ConnectionFailedException(
    String deviceId, {
    this.retryable = true,
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(deviceId, message ?? 'Failed to connect to $deviceId');

  final bool retryable;

  @override
  bool get isRetryable => retryable;
}

/// The link dropped while an operation was pending or before it was sent.
final class DeviceDisconnectedException extends DeviceException {
  const DeviceDisconnectedException(
    String deviceId, {
    this.operation,
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(deviceId, message ?? 'Device disconnected: $deviceId');

  /// The operation that was aborted, if any.
  final BluetoothOperation? operation;

  @override
  bool get isRetryable => true;
}

/// An operation did not complete within its time limit.
final class OperationTimeoutException extends DeviceException {
  OperationTimeoutException(
    String deviceId,
    this.operation,
    this.timeout, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(
         deviceId,
         message ??
             '${operation.name} on $deviceId timed out after '
                 '${timeout.inMilliseconds}ms',
       );

  final BluetoothOperation operation;
  final Duration timeout;

  @override
  bool get isRetryable => true;
}

/// An operation was cancelled before it completed, for example because the
/// caller disconnected or disposed the device.
final class OperationCancelledException extends DeviceException {
  OperationCancelledException(
    String deviceId,
    this.operation, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(
         deviceId,
         message ?? '${operation.name} on $deviceId was cancelled',
       );

  final BluetoothOperation operation;
}

/// The remote device answered with a GATT or ATT error status.
final class GattException extends DeviceException {
  GattException(
    String deviceId,
    this.operation,
    this.status, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(
         deviceId,
         message ??
             '${operation.name} on $deviceId failed with GATT status '
                 '0x${status.toRadixString(16).padLeft(2, '0')}',
       );

  final BluetoothOperation operation;

  /// The ATT error code from the Bluetooth Core specification, for example
  /// 0x05 for insufficient authentication.
  final int status;

  /// True for statuses that mean the link has to be paired or encrypted
  /// first (insufficient authentication, authorization or encryption).
  bool get requiresBonding =>
      status == 0x05 || status == 0x08 || status == 0x0F;
}

/// The service, characteristic or descriptor was not found on the device.
final class AttributeNotFoundException extends DeviceException {
  const AttributeNotFoundException(
    String deviceId,
    this.attributeUuid, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(
         deviceId,
         message ?? 'Attribute $attributeUuid not found on $deviceId',
       );

  final String attributeUuid;
}

/// Pairing or bonding with the device failed or was rejected.
final class BondingFailedException extends DeviceException {
  const BondingFailedException(
    String deviceId, {
    String? message,
    super.platformCode,
    super.platformMessage,
  }) : super(deviceId, message ?? 'Bonding with $deviceId failed');
}

/// A native error that does not map to a more specific type.
final class UnknownBluetoothException extends VitalBluetoothException {
  const UnknownBluetoothException(
    super.message, {
    super.platformCode,
    super.platformMessage,
  });
}
