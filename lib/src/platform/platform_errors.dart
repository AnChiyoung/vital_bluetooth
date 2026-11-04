import 'package:flutter/services.dart';

import '../core/errors.dart';
import '../core/operation.dart';
import 'messages.g.dart';

/// The error codes the platforms use. See the table in pigeons/messages.dart.
abstract final class PlatformErrorCode {
  static const unsupported = 'unsupported';
  static const poweredOff = 'poweredOff';
  static const permissionDenied = 'permissionDenied';
  static const deviceNotFound = 'deviceNotFound';
  static const notConnected = 'notConnected';
  static const connectionFailed = 'connectionFailed';
  static const gattError = 'gattError';
  static const attributeNotFound = 'attributeNotFound';
  static const bondingFailed = 'bondingFailed';
  static const locationServicesOff = 'locationServicesOff';
  static const unknown = 'unknown';

  /// Thrown by the generated code when no platform side is registered.
  static const channelError = 'channel-error';
}

/// Turns an error thrown by a host API call into a [VitalBluetoothException].
///
/// [deviceId] and [operation] describe the call, so the exception can say
/// which device and which operation failed.
VitalBluetoothException fromPlatformException(
  PlatformException error, {
  String? deviceId,
  BluetoothOperation? operation,
}) {
  final details = error.details;
  return _map(
    code: error.code,
    message: error.message,
    platformCode: switch (details) {
      String() => details,
      int() => details.toString(),
      _ => null,
    },
    details: details,
    deviceId: deviceId,
    operation: operation,
  );
}

/// Turns an error reported with an event, such as a dropped link, into a
/// [VitalBluetoothException].
VitalBluetoothException fromPlatformErrorMessage(
  PlatformErrorMessage error, {
  String? deviceId,
  BluetoothOperation? operation,
}) {
  return _map(
    code: error.code,
    message: error.message,
    platformCode: error.platformCode,
    details: int.tryParse(error.platformCode ?? ''),
    deviceId: deviceId,
    operation: operation,
  );
}

/// Runs a host API [call] and rethrows its platform errors as
/// [VitalBluetoothException]s.
Future<T> guardPlatformCall<T>(
  Future<T> Function() call, {
  String? deviceId,
  BluetoothOperation? operation,
}) async {
  try {
    return await call();
  } on PlatformException catch (e) {
    throw fromPlatformException(e, deviceId: deviceId, operation: operation);
  }
}

VitalBluetoothException _map({
  required String code,
  required String? message,
  required String? platformCode,
  required Object? details,
  required String? deviceId,
  required BluetoothOperation? operation,
}) {
  final device = deviceId ?? '';
  switch (code) {
    case PlatformErrorCode.unsupported:
      return FeatureNotSupportedException(
        operation?.name ?? 'unknown',
        message: message,
        platformMessage: message,
      );
    case PlatformErrorCode.poweredOff:
      return AdapterUnavailableException(
        AdapterUnavailableReason.poweredOff,
        platformMessage: message,
      );
    case PlatformErrorCode.permissionDenied:
      return PermissionDeniedException(
        details is List ? details.whereType<String>().toList() : const [],
        platformMessage: message,
      );
    case PlatformErrorCode.deviceNotFound:
      return DeviceNotFoundException(device, platformMessage: message);
    case PlatformErrorCode.notConnected:
      return DeviceDisconnectedException(
        device,
        operation: operation,
        platformCode: platformCode,
        platformMessage: message,
      );
    case PlatformErrorCode.connectionFailed:
      return ConnectionFailedException(
        device,
        platformCode: platformCode,
        platformMessage: message,
      );
    case PlatformErrorCode.gattError:
      final status = details is int ? details : int.tryParse('$details');
      if (status != null) {
        return GattException(
          device,
          operation ?? BluetoothOperation.read,
          status,
          platformCode: platformCode,
          platformMessage: message,
        );
      }
    case PlatformErrorCode.attributeNotFound:
      return AttributeNotFoundException(
        device,
        details is String ? details : 'unknown',
        platformMessage: message,
      );
    case PlatformErrorCode.locationServicesOff:
      return LocationServicesDisabledException(platformMessage: message);
    case PlatformErrorCode.bondingFailed:
      return BondingFailedException(
        device,
        platformCode: platformCode,
        platformMessage: message,
      );
    case PlatformErrorCode.channelError:
      return UnknownBluetoothException(
        'The vital_bluetooth platform side is not registered. '
        'Was the app fully restarted after adding the plugin?',
        platformCode: code,
        platformMessage: message,
      );
  }
  return UnknownBluetoothException(
    message ?? 'Unknown platform error: $code',
    platformCode: platformCode ?? code,
    platformMessage: message,
  );
}
