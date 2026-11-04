import 'package:flutter/foundation.dart';

import 'platform/messages.g.dart';

/// The state of the phone's or computer's Bluetooth adapter.
enum AdapterState {
  /// Not reported yet.
  unknown,

  /// No Bluetooth LE hardware.
  unsupported,

  /// The app may not use Bluetooth (iOS and macOS).
  unauthorized,
  poweredOff,
  turningOn,
  poweredOn,
  turningOff;

  bool get isOn => this == poweredOn;
}

enum PermissionStatus {
  granted,
  denied,

  /// The user chose "don't ask again". Only the system settings can change
  /// it now.
  permanentlyDenied;

  bool get isGranted => this == granted;
}

/// How hard Android scans. Other platforms ignore it.
enum ScanMode { lowPower, balanced, lowLatency }

/// Android only.
enum ConnectionPriority { balanced, high, lowPower }

/// The radio mode. Android only; 2M is faster, Coded reaches further.
enum Phy { le1m, le2m, leCoded }

enum BondState { none, bonding, bonded }

@immutable
class CharacteristicProperties {
  const CharacteristicProperties({
    this.broadcast = false,
    this.read = false,
    this.writeWithoutResponse = false,
    this.write = false,
    this.notify = false,
    this.indicate = false,
    this.authenticatedSignedWrites = false,
    this.extendedProperties = false,
  });

  final bool broadcast;
  final bool read;
  final bool writeWithoutResponse;
  final bool write;
  final bool notify;
  final bool indicate;
  final bool authenticatedSignedWrites;
  final bool extendedProperties;

  /// Whether [BluetoothCharacteristic.setNotify] works.
  bool get canSubscribe => notify || indicate;

  @override
  String toString() => [
    if (broadcast) 'broadcast',
    if (read) 'read',
    if (writeWithoutResponse) 'writeWithoutResponse',
    if (write) 'write',
    if (notify) 'notify',
    if (indicate) 'indicate',
    if (authenticatedSignedWrites) 'authenticatedSignedWrites',
    if (extendedProperties) 'extendedProperties',
  ].join(', ');
}

// Conversions between the Pigeon messages and the public types.

AdapterState adapterStateFrom(AdapterStateMessage m) =>
    AdapterState.values[m.index];

PermissionStatus permissionStatusFrom(PermissionStatusMessage m) =>
    PermissionStatus.values[m.index];

BondState bondStateFrom(BondStateMessage m) => BondState.values[m.index];

CharacteristicProperties propertiesFrom(CharacteristicPropertiesMessage m) =>
    CharacteristicProperties(
      broadcast: m.broadcast,
      read: m.read,
      writeWithoutResponse: m.writeWithoutResponse,
      write: m.write,
      notify: m.notify,
      indicate: m.indicate,
      authenticatedSignedWrites: m.authenticatedSignedWrites,
      extendedProperties: m.extendedProperties,
    );
