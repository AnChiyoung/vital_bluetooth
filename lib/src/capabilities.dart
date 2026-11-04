import 'package:flutter/foundation.dart';

/// What Bluetooth features the current platform supports.
///
/// Check these before calling a feature that isn't available everywhere,
/// for example Classic, which iOS doesn't support.
@immutable
class BluetoothCapabilities {
  const BluetoothCapabilities({
    required this.ble,
    required this.classic,
    required this.bonding,
    required this.connectionPriority,
    required this.phy,
  });

  /// Bluetooth Low Energy.
  final bool ble;

  /// Classic RFCOMM / SPP. False on iOS, which needs MFi for it.
  final bool classic;

  /// Creating and removing bonds from the app (Android and Windows).
  final bool bonding;

  /// Requesting a connection priority (Android).
  final bool connectionPriority;

  /// Choosing 2M or Coded PHY (Android).
  final bool phy;

  @override
  bool operator ==(Object other) =>
      other is BluetoothCapabilities &&
      other.ble == ble &&
      other.classic == classic &&
      other.bonding == bonding &&
      other.connectionPriority == connectionPriority &&
      other.phy == phy;

  @override
  int get hashCode =>
      Object.hash(ble, classic, bonding, connectionPriority, phy);

  @override
  String toString() =>
      'BluetoothCapabilities(ble: $ble, classic: $classic, bonding: $bonding, '
      'connectionPriority: $connectionPriority, phy: $phy)';
}
