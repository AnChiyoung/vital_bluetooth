// The contract between the Dart side of vital_bluetooth and each platform.
//
// After changing this file, regenerate the code with:
//   dart run pigeon --input pigeons/messages.dart
//   dart format lib/src/platform pigeons
//
// Conventions every platform follows:
// - Calls from Dart go through the *HostApi classes. Events from the platform
//   (scan results, link changes, notifications) come back through the
//   *FlutterApi classes, so Windows (C++) works the same as Kotlin and Swift.
// - UUIDs are lowercase 128-bit strings ("0000180d-0000-1000-8000-00805f9b34fb").
// - A characteristic is addressed by its UUIDs plus an instance number that
//   the platform assigns during discovery. Some devices expose two services
//   or characteristics with the same UUID, and the UUID alone can't tell them
//   apart.
// - A failed call throws a platform error whose code is one of the codes
//   below. The Dart side turns it into a VitalBluetoothException
//   (lib/src/platform/platform_errors.dart).
//
//   code               meaning                          details
//   unsupported        the platform can't do this       -
//   poweredOff         the Bluetooth adapter is off     -
//   permissionDenied   a permission is missing          List<String> of names
//   deviceNotFound     unknown device ID                -
//   notConnected       the call needs a connected link  -
//   connectionFailed   the link couldn't be opened      String: raw status
//   gattError          the device answered an error     int: ATT status
//   attributeNotFound  no such service/char/descriptor  String: its UUID
//   bondingFailed      pairing failed or was rejected   String: raw status
//   unknown            anything else                    String: raw status
//
//   PlatformErrorMessage in events uses the same codes, with the raw status
//   in platformCode.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/platform/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/dev/goodluckcy/vital_bluetooth/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'dev.goodluckcy.vital_bluetooth',
      errorClassName: 'VitalBluetoothError',
    ),
    swiftOut: 'darwin/vital_bluetooth/Sources/vital_bluetooth/Messages.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'VitalBluetoothError'),
    cppHeaderOut: 'windows/messages.g.h',
    cppSourceOut: 'windows/messages.g.cpp',
    cppOptions: CppOptions(namespace: 'vital_bluetooth'),
    dartPackageName: 'vital_bluetooth',
  ),
)
// ---------------------------------------------------------------------------
// Adapter and permissions
// ---------------------------------------------------------------------------
enum AdapterStateMessage {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  turningOn,
  poweredOn,
  turningOff,
}

enum PermissionStatusMessage {
  granted,
  denied,

  /// The user said "don't ask again". Only the system settings can fix it.
  permanentlyDenied,
}

/// What the platform supports, so the Dart side can fail early and clearly.
class CapabilitiesMessage {
  CapabilitiesMessage({
    required this.ble,
    required this.classic,
    required this.bonding,
    required this.connectionPriority,
    required this.phy,
  });

  bool ble;

  /// Classic RFCOMM/SPP. False on iOS (needs MFi).
  bool classic;

  /// Creating and removing bonds from the app. Android and Windows only.
  bool bonding;

  /// Android only.
  bool connectionPriority;

  /// Choosing 2M or Coded PHY. Android only.
  bool phy;
}

// ---------------------------------------------------------------------------
// BLE scanning
// ---------------------------------------------------------------------------
enum ScanModeMessage { lowPower, balanced, lowLatency }

class ScanSettingsMessage {
  ScanSettingsMessage({
    required this.serviceUuids,
    required this.mode,
    required this.allowDuplicates,
  });

  /// Only report devices that advertise one of these services. Empty means
  /// no filter. iOS can only scan in the background with a filter.
  List<String> serviceUuids;

  /// Android only. Other platforms ignore it.
  ScanModeMessage mode;

  /// Report every advertisement instead of once per device. Needed for
  /// devices that put live readings in their advertisements.
  bool allowDuplicates;
}

class ScanResultMessage {
  ScanResultMessage({
    required this.deviceId,
    required this.rssi,
    required this.connectable,
    required this.serviceUuids,
    required this.manufacturerData,
    required this.serviceData,
    this.name,
    this.txPowerLevel,
  });

  /// MAC address on Android and Windows, a UUID that CoreBluetooth makes up
  /// on iOS and macOS.
  String deviceId;
  String? name;
  int rssi;
  bool connectable;
  int? txPowerLevel;
  List<String> serviceUuids;

  /// Company ID -> data.
  Map<int, Uint8List> manufacturerData;

  /// Service UUID -> data.
  Map<String, Uint8List> serviceData;
}

/// A device the system already knows about: connected by another app, or
/// bonded.
class SystemDeviceMessage {
  SystemDeviceMessage({required this.deviceId, this.name});

  String deviceId;
  String? name;
}

// ---------------------------------------------------------------------------
// BLE connection and GATT
// ---------------------------------------------------------------------------
enum ConnectionStateMessage {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

enum ConnectionPriorityMessage { balanced, high, lowPower }

enum PhyMessage { le1m, le2m, leCoded }

enum BondStateMessage { none, bonding, bonded }

class CharacteristicPropertiesMessage {
  CharacteristicPropertiesMessage({
    required this.broadcast,
    required this.read,
    required this.writeWithoutResponse,
    required this.write,
    required this.notify,
    required this.indicate,
    required this.authenticatedSignedWrites,
    required this.extendedProperties,
  });

  bool broadcast;
  bool read;
  bool writeWithoutResponse;
  bool write;
  bool notify;
  bool indicate;
  bool authenticatedSignedWrites;
  bool extendedProperties;
}

class DescriptorMessage {
  DescriptorMessage({required this.uuid});

  String uuid;
}

class CharacteristicMessage {
  CharacteristicMessage({
    required this.uuid,
    required this.instance,
    required this.properties,
    required this.descriptors,
  });

  String uuid;
  int instance;
  CharacteristicPropertiesMessage properties;
  List<DescriptorMessage> descriptors;
}

class ServiceMessage {
  ServiceMessage({
    required this.uuid,
    required this.instance,
    required this.isPrimary,
    required this.characteristics,
    required this.includedServices,
  });

  String uuid;
  int instance;
  bool isPrimary;
  List<CharacteristicMessage> characteristics;

  /// UUIDs of services this one includes.
  List<String> includedServices;
}

class CharacteristicAddressMessage {
  CharacteristicAddressMessage({
    required this.deviceId,
    required this.serviceUuid,
    required this.serviceInstance,
    required this.characteristicUuid,
    required this.characteristicInstance,
  });

  String deviceId;
  String serviceUuid;
  int serviceInstance;
  String characteristicUuid;
  int characteristicInstance;
}

/// One notification or indication.
class CharacteristicValueMessage {
  CharacteristicValueMessage({
    required this.characteristic,
    required this.value,
    required this.timestampMicros,
  });

  CharacteristicAddressMessage characteristic;
  Uint8List value;

  /// When the platform received it, in microseconds since the Unix epoch.
  /// Values may reach Dart in batches, so this keeps the real timing for
  /// signals like ECG.
  int timestampMicros;
}

/// Why a connection or scan ended, when the platform says.
class PlatformErrorMessage {
  PlatformErrorMessage({required this.code, this.message, this.platformCode});

  /// One of the error codes at the top of this file.
  String code;
  String? message;

  /// The raw platform value, such as Android's GATT status 133.
  String? platformCode;
}

@HostApi()
abstract class BleHostApi {
  CapabilitiesMessage getCapabilities();

  AdapterStateMessage getAdapterState();

  /// Turns the adapter on. Android before 13 only; others throw unsupported.
  @async
  void turnOn();

  PermissionStatusMessage getPermissionStatus();

  @async
  PermissionStatusMessage requestPermissions();

  /// Results arrive through BleFlutterApi.onScanResult.
  @async
  void startScan(ScanSettingsMessage settings);

  void stopScan();

  /// Devices already connected to the system that offer one of these
  /// services. They still need connect() before use in this app.
  @async
  List<SystemDeviceMessage> getSystemDevices(List<String> serviceUuids);

  /// Completes when the link is up. Discovery is a separate call.
  @async
  void connect(String deviceId, bool autoConnect);

  /// Completes when the link is down. Never throws notConnected.
  @async
  void disconnect(String deviceId);

  @async
  List<ServiceMessage> discoverServices(String deviceId);

  @async
  Uint8List readCharacteristic(CharacteristicAddressMessage characteristic);

  @async
  void writeCharacteristic(
    CharacteristicAddressMessage characteristic,
    Uint8List value,
    bool withResponse,
  );

  /// Turns notifications (or indications, when that's all the
  /// characteristic supports) on or off, including the CCCD write.
  @async
  void setNotify(CharacteristicAddressMessage characteristic, bool enable);

  @async
  Uint8List readDescriptor(
    CharacteristicAddressMessage characteristic,
    String descriptorUuid,
  );

  @async
  void writeDescriptor(
    CharacteristicAddressMessage characteristic,
    String descriptorUuid,
    Uint8List value,
  );

  /// Returns the MTU the devices agreed on. iOS and macOS choose it
  /// themselves and return the current one.
  @async
  int requestMtu(String deviceId, int mtu);

  /// The largest value one write can carry.
  int getMaximumWriteLength(String deviceId, bool withResponse);

  @async
  void requestConnectionPriority(
    String deviceId,
    ConnectionPriorityMessage priority,
  );

  @async
  void setPreferredPhy(String deviceId, PhyMessage tx, PhyMessage rx);

  @async
  int readRssi(String deviceId);

  BondStateMessage getBondState(String deviceId);

  @async
  void createBond(String deviceId);

  @async
  void removeBond(String deviceId);
}

@FlutterApi()
abstract class BleFlutterApi {
  void onAdapterStateChanged(AdapterStateMessage state);

  /// Results come in batches to keep channel traffic down while scanning.
  void onScanResults(List<ScanResultMessage> results);

  /// The scan stopped on its own, for example because the adapter turned off.
  void onScanStopped(PlatformErrorMessage? error);

  /// error is set when the link dropped without a disconnect() call.
  void onConnectionStateChanged(
    String deviceId,
    ConnectionStateMessage state,
    PlatformErrorMessage? error,
  );

  /// Notifications come in batches. A fast sensor can send hundreds a second,
  /// and one channel message per value would be too slow.
  void onCharacteristicValues(List<CharacteristicValueMessage> values);

  /// The device changed its services (Service Changed indication).
  void onServicesChanged(String deviceId);

  void onMtuChanged(String deviceId, int mtu);

  void onBondStateChanged(String deviceId, BondStateMessage state);
}

// ---------------------------------------------------------------------------
// Classic (RFCOMM / SPP)
// Android, macOS and Windows. iOS throws unsupported.
// ---------------------------------------------------------------------------
class ClassicDeviceMessage {
  ClassicDeviceMessage({
    required this.deviceId,
    required this.bondState,
    this.name,
    this.rssi,
    this.deviceClass,
  });

  String deviceId;
  String? name;

  /// Only set for devices found by discovery.
  int? rssi;

  /// The Class of Device value, which says what kind of device this is.
  int? deviceClass;
  BondStateMessage bondState;
}

@HostApi()
abstract class ClassicHostApi {
  @async
  List<ClassicDeviceMessage> getBondedDevices();

  /// Results arrive through ClassicFlutterApi.onDeviceDiscovered.
  @async
  void startDiscovery();

  @async
  void stopDiscovery();

  /// Opens an RFCOMM socket to serviceUuid, usually the SPP UUID
  /// 00001101-0000-1000-8000-00805f9b34fb. secure = false skips
  /// authentication, which some cheap modules need.
  @async
  void connect(String deviceId, String serviceUuid, bool secure);

  @async
  void disconnect(String deviceId);

  @async
  void write(String deviceId, Uint8List data);
}

@FlutterApi()
abstract class ClassicFlutterApi {
  void onDeviceDiscovered(ClassicDeviceMessage device);

  void onDiscoveryFinished();

  void onData(String deviceId, Uint8List data);

  /// error is set when the socket closed without a disconnect() call.
  void onDisconnected(String deviceId, PlatformErrorMessage? error);
}
