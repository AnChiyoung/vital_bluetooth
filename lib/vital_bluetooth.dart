/// Reliable Bluetooth LE and Classic for wearables and healthcare devices.
///
/// Start with [VitalBluetooth]:
///
/// ```dart
/// final bluetooth = VitalBluetooth();
/// await bluetooth.requestPermissions();
/// final result = await bluetooth.scan(withServices: ['180d']).first;
/// final device = result.device;
/// await device.connect();
/// final heartRate = device.characteristic('180d', '2a37')!;
/// heartRate.values.listen(print);
/// await heartRate.setNotify(true);
/// ```
library;

import 'src/vital_bluetooth_base.dart';

export 'src/bluetooth_device.dart'
    show
        BluetoothCharacteristic,
        BluetoothDevice,
        BluetoothService,
        CharacteristicValue;
export 'src/capabilities.dart';
export 'src/core/connection_options.dart';
export 'src/core/connection_state.dart';
export 'src/core/errors.dart';
export 'src/core/operation.dart';
export 'src/models.dart'
    show
        AdapterState,
        BondState,
        CharacteristicProperties,
        ConnectionPriority,
        PermissionStatus,
        Phy,
        ScanMode;
export 'src/uuid.dart';
export 'src/vital_bluetooth_base.dart'
    show BackgroundValue, ScanResult, VitalBluetooth;
