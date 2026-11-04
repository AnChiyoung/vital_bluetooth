#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// iOS and macOS side of BleHostApi, on CoreBluetooth.
///
/// Only the API shape is in place so far. Every call that isn't implemented
/// yet throws an `unsupported` error.
final class BleHost: BleHostApi {
  private let events: BleFlutterApi

  init(events: BleFlutterApi) {
    self.events = events
  }

  func getCapabilities() throws -> CapabilitiesMessage {
    #if os(iOS)
    let classic = false  // Needs MFi.
    #else
    let classic = true  // IOBluetooth.
    #endif
    return CapabilitiesMessage(
      ble: true,
      classic: classic,
      bonding: false,
      connectionPriority: false,
      phy: false
    )
  }

  func getAdapterState() throws -> AdapterStateMessage { throw notImplemented() }
  func turnOn() async throws { throw unsupported("Apps can't turn Bluetooth on here.") }
  func getPermissionStatus() throws -> PermissionStatusMessage { throw notImplemented() }
  func requestPermissions() async throws -> PermissionStatusMessage { throw notImplemented() }
  func startScan(settings: ScanSettingsMessage) async throws { throw notImplemented() }
  func stopScan() throws { throw notImplemented() }

  func getSystemDevices(serviceUuids: [String]) async throws -> [SystemDeviceMessage] {
    throw notImplemented()
  }

  func connect(deviceId: String, autoConnect: Bool) async throws { throw notImplemented() }
  func disconnect(deviceId: String) async throws { throw notImplemented() }

  func discoverServices(deviceId: String) async throws -> [ServiceMessage] {
    throw notImplemented()
  }

  func readCharacteristic(
    characteristic: CharacteristicAddressMessage
  ) async throws -> FlutterStandardTypedData {
    throw notImplemented()
  }

  func writeCharacteristic(
    characteristic: CharacteristicAddressMessage,
    value: FlutterStandardTypedData,
    withResponse: Bool
  ) async throws {
    throw notImplemented()
  }

  func setNotify(characteristic: CharacteristicAddressMessage, enable: Bool) async throws {
    throw notImplemented()
  }

  func readDescriptor(
    characteristic: CharacteristicAddressMessage,
    descriptorUuid: String
  ) async throws -> FlutterStandardTypedData {
    throw notImplemented()
  }

  func writeDescriptor(
    characteristic: CharacteristicAddressMessage,
    descriptorUuid: String,
    value: FlutterStandardTypedData
  ) async throws {
    throw notImplemented()
  }

  func requestMtu(deviceId: String, mtu: Int64) async throws -> Int64 { throw notImplemented() }

  func getMaximumWriteLength(deviceId: String, withResponse: Bool) throws -> Int64 {
    throw notImplemented()
  }

  func requestConnectionPriority(
    deviceId: String,
    priority: ConnectionPriorityMessage
  ) async throws {
    throw unsupported("Connection priority is Android only.")
  }

  func setPreferredPhy(deviceId: String, tx: PhyMessage, rx: PhyMessage) async throws {
    throw unsupported("Choosing the PHY is Android only.")
  }

  func readRssi(deviceId: String) async throws -> Int64 { throw notImplemented() }
  func getBondState(deviceId: String) throws -> BondStateMessage { throw notImplemented() }

  func createBond(deviceId: String) async throws {
    throw unsupported("The system pairs on its own when a device needs it.")
  }

  func removeBond(deviceId: String) async throws {
    throw unsupported("Bonds can only be removed in the system settings.")
  }

  func enableBackgroundMode(notification: BackgroundNotificationMessage) async throws {
    throw notImplemented()
  }

  func disableBackgroundMode() throws {}
  func isBackgroundModeEnabled() throws -> Bool { false }
  func getSession(deviceId: String) throws -> SessionMessage? { nil }
  func getSessions() throws -> [SessionMessage] { [] }
  func takeBufferedValues() throws -> [CharacteristicValueMessage] { [] }
}

func unsupported(_ message: String) -> VitalBluetoothError {
  VitalBluetoothError(code: "unsupported", message: message, details: nil)
}

func notImplemented() -> VitalBluetoothError {
  unsupported("Not implemented on this platform yet.")
}
