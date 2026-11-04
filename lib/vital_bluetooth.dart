import 'package:flutter/foundation.dart';

import 'src/capabilities.dart';
import 'src/platform/messages.g.dart';

export 'src/capabilities.dart';
export 'src/core/connection_options.dart';
export 'src/core/connection_state.dart';
export 'src/core/errors.dart';
export 'src/core/operation.dart';

/// Entry point of vital_bluetooth.
class VitalBluetooth {
  VitalBluetooth() : _ble = BleHostApi();

  /// Uses [bleApi] in place of the platform, for tests.
  @visibleForTesting
  VitalBluetooth.withApi(BleHostApi bleApi) : _ble = bleApi;

  final BleHostApi _ble;

  /// What the current platform supports.
  Future<BluetoothCapabilities> getCapabilities() async {
    final caps = await _ble.getCapabilities();
    return BluetoothCapabilities(
      ble: caps.ble,
      classic: caps.classic,
      bonding: caps.bonding,
      connectionPriority: caps.connectionPriority,
      phy: caps.phy,
    );
  }
}
