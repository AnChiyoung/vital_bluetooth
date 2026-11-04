import CoreBluetooth
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// iOS and macOS side of BleHostApi, on CoreBluetooth.
///
/// Everything runs on the main thread: Pigeon calls in on it, and the
/// central manager delivers its callbacks on the main queue.
///
/// The central manager is created lazily, because creating it shows the
/// Bluetooth permission prompt. It is created at once when permission was
/// already given, or when background mode was on at the last launch (state
/// restoration needs it during launch).
///
/// Background mode on iOS: the app is suspended in the background, so Dart
/// timers stop. A dropped link is therefore reconnected here right away;
/// CoreBluetooth keeps the connect pending with no time limit and wakes the
/// app when the device is back. Notifications are turned back on natively.
/// With state restoration, iOS relaunches the app in the background for a
/// device event after it was terminated for memory.
final class BleHost: NSObject, BleHostApi, CBCentralManagerDelegate {
  private static let backgroundKey = "dev.goodluckcy.vital_bluetooth.backgroundMode"
  private static let restoreIdentifier = "dev.goodluckcy.vital_bluetooth.central"

  private let events: EventSender
  private var central: CBCentralManager?
  private var stateWaits: [CheckedContinuation<Void, Never>] = []
  private var peripherals: [String: CBPeripheral] = [:]
  private var sessions: [String: PeripheralSession] = [:]
  private var scanning = false
  private var backgroundMode: Bool

  // Devices Dart asked to connect and has not disconnected, with the
  // characteristics it turned notifications on for, by address key.
  private var wanted: [String: [String: CharacteristicAddressMessage]] = [:]

  init(events: BleFlutterApi) {
    self.events = EventSender(api: events)
    backgroundMode = UserDefaults.standard.bool(forKey: BleHost.backgroundKey)
    super.init()
    self.events.buffering = backgroundMode
    if backgroundMode || CBManager.authorization == .allowedAlways {
      _ = ensureCentral()
    }
  }

  // MARK: Adapter and permissions

  func getCapabilities() throws -> CapabilitiesMessage {
    CapabilitiesMessage(
      ble: true,
      classic: false,  // iOS needs MFi; macOS Classic isn't written yet.
      bonding: false,
      connectionPriority: false,
      phy: false
    )
  }

  func getAdapterState() throws -> AdapterStateMessage {
    guard let central = central else {
      return CBManager.authorization == .notDetermined ? .unknown : adapterState(of: nil)
    }
    return adapterState(of: central)
  }

  func turnOn() async throws {
    throw unsupported("Apps can't turn Bluetooth on here.")
  }

  func getPermissionStatus() throws -> PermissionStatusMessage {
    permissionStatus()
  }

  @MainActor
  func requestPermissions() async throws -> PermissionStatusMessage {
    if CBManager.authorization == .notDetermined {
      // Creating the manager shows the prompt; its first state update
      // comes once the user has answered.
      let central = ensureCentral()
      if central.state == .unknown { await waitForState() }
    }
    return permissionStatus()
  }

  // MARK: Scanning

  @MainActor
  func startScan(settings: ScanSettingsMessage) async throws {
    let central = try await requireOn()
    let services = settings.serviceUuids.map { CBUUID(string: $0) }
    central.scanForPeripherals(
      withServices: services.isEmpty ? nil : services,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: settings.allowDuplicates]
    )
    scanning = true
  }

  func stopScan() throws {
    scanning = false
    central?.stopScan()
  }

  @MainActor
  func getSystemDevices(serviceUuids: [String]) async throws -> [SystemDeviceMessage] {
    let central = try await requireOn()
    // CoreBluetooth only lists connected devices by service. Every device
    // has Generic Access, and most have Device Information.
    let uuids =
      serviceUuids.isEmpty
      ? [CBUUID(string: "1800"), CBUUID(string: "180A")]
      : serviceUuids.map { CBUUID(string: $0) }
    return central.retrieveConnectedPeripherals(withServices: uuids).map { p in
      peripherals[p.identifier.uuidString] = p
      return SystemDeviceMessage(deviceId: p.identifier.uuidString, name: p.name)
    }
  }

  // MARK: Connection

  @MainActor
  func connect(deviceId: String, autoConnect: Bool) async throws {
    let central = try await requireOn()
    events.claim(deviceId)
    if wanted[deviceId] == nil { wanted[deviceId] = [:] }
    let session = try self.session(for: deviceId, central: central)
    if session.isConnected { return }
    // A connect may already be pending, for example a native reconnect.
    if !session.isConnecting {
      events.connectionState(deviceId, .connecting)
      central.connect(session.peripheral, options: nil)
    }
    try await session.waitForConnect()
  }

  @MainActor
  func disconnect(deviceId: String, forget: Bool) async throws {
    guard let session = sessions[deviceId] else {
      if forget { wanted[deviceId] = nil }
      return
    }
    if forget {
      wanted[deviceId] = nil
    } else if !session.isConnected {
      // Only a failed attempt is being cleaned up. A CoreBluetooth connect
      // has no time limit, so leaving it pending is the best next attempt.
      return
    }
    if !session.isConnected {
      // A pending connect: cancelling it gets no callback, so fail its
      // callers here.
      if session.isConnecting || session.peripheral.state == .connecting {
        central?.cancelPeripheralConnection(session.peripheral)
        session.abort(notConnected(deviceId))
        events.connectionState(deviceId, .disconnected)
      }
      return
    }
    events.connectionState(deviceId, .disconnecting)
    central?.cancelPeripheralConnection(session.peripheral)
    await session.waitForDisconnect(timeout: 2)
  }

  @MainActor
  func discoverServices(deviceId: String) async throws -> [ServiceMessage] {
    try await connected(deviceId).discoverServices()
  }

  // MARK: GATT

  @MainActor
  func readCharacteristic(characteristic: CharacteristicAddressMessage) async throws
    -> FlutterStandardTypedData
  {
    try await connected(characteristic.deviceId).read(characteristic)
  }

  @MainActor
  func writeCharacteristic(
    characteristic: CharacteristicAddressMessage,
    value: FlutterStandardTypedData,
    withResponse: Bool
  ) async throws {
    try await connected(characteristic.deviceId).write(
      characteristic, value.data, withResponse: withResponse)
  }

  @MainActor
  func setNotify(characteristic: CharacteristicAddressMessage, enable: Bool) async throws {
    try await connected(characteristic.deviceId).setNotify(characteristic, enable)
    guard wanted[characteristic.deviceId] != nil else { return }
    wanted[characteristic.deviceId]?[key(of: characteristic)] = enable ? characteristic : nil
  }

  @MainActor
  func readDescriptor(characteristic: CharacteristicAddressMessage, descriptorUuid: String)
    async throws -> FlutterStandardTypedData
  {
    try await connected(characteristic.deviceId).readDescriptor(characteristic, descriptorUuid)
  }

  @MainActor
  func writeDescriptor(
    characteristic: CharacteristicAddressMessage,
    descriptorUuid: String,
    value: FlutterStandardTypedData
  ) async throws {
    try await connected(characteristic.deviceId).writeDescriptor(
      characteristic, descriptorUuid, value.data)
  }

  /// Apple negotiates the MTU itself; this reports the current one.
  @MainActor
  func requestMtu(deviceId: String, mtu: Int64) async throws -> Int64 {
    let session = try connected(deviceId)
    let current = session.maximumWriteLength(withResponse: false) + 3
    events.mtuChanged(deviceId, current)
    return Int64(current)
  }

  func getMaximumWriteLength(deviceId: String, withResponse: Bool) throws -> Int64 {
    try Int64(connected(deviceId).maximumWriteLength(withResponse: withResponse))
  }

  func requestConnectionPriority(deviceId: String, priority: ConnectionPriorityMessage)
    async throws
  {
    throw unsupported("Apple chooses the connection parameters itself.")
  }

  func setPreferredPhy(deviceId: String, tx: PhyMessage, rx: PhyMessage) async throws {
    throw unsupported("Apple chooses the PHY itself.")
  }

  @MainActor
  func readRssi(deviceId: String) async throws -> Int64 {
    try await connected(deviceId).readRssi()
  }

  // MARK: Bonding (the system pairs on its own when a characteristic needs it)

  func getBondState(deviceId: String) throws -> BondStateMessage {
    throw unsupported("Apple doesn't tell apps whether a device is paired.")
  }

  func createBond(deviceId: String) async throws {
    throw unsupported("Apple pairs on its own when a protected characteristic is used.")
  }

  func removeBond(deviceId: String) async throws {
    throw unsupported("Bonds can only be removed in the system settings.")
  }

  // MARK: Background mode

  @MainActor
  func enableBackgroundMode(notification: BackgroundNotificationMessage) async throws {
    #if os(iOS)
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    if !modes.contains("bluetooth-central") {
      throw unsupported(
        "Add bluetooth-central to UIBackgroundModes in the app's Info.plist for background mode.")
    }
    #endif
    // macOS doesn't suspend apps, so links already survive the background.
    backgroundMode = true
    events.buffering = true
    UserDefaults.standard.set(true, forKey: BleHost.backgroundKey)
  }

  func disableBackgroundMode() throws {
    backgroundMode = false
    events.buffering = false
    UserDefaults.standard.set(false, forKey: BleHost.backgroundKey)
  }

  func isBackgroundModeEnabled() throws -> Bool { backgroundMode }

  func getSession(deviceId: String) throws -> SessionMessage? {
    events.claim(deviceId)
    return sessionMessage(deviceId)
  }

  func getSessions() throws -> [SessionMessage] {
    wanted.keys.compactMap { sessionMessage($0) }
  }

  func takeBufferedValues() throws -> [CharacteristicValueMessage] {
    events.takeBuffered()
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    events.adapterState(adapterState(of: central))
    let waits = stateWaits
    stateWaits = []
    waits.forEach { $0.resume() }
    if central.state == .poweredOn {
      // Links wanted while Bluetooth was off: start the pending connects.
      if backgroundMode {
        for deviceId in wanted.keys { reconnectNatively(deviceId) }
      }
      return
    }
    if scanning {
      scanning = false
      events.scanStopped(PlatformErrorMessage(code: "poweredOff", message: "Bluetooth turned off."))
    }
    if central.state == .poweredOff || central.state == .unauthorized {
      // iOS doesn't reliably report each link going down here.
      for session in sessions.values {
        session.abort(notConnected(session.deviceId))
        events.connectionState(session.deviceId, .disconnected, dropMessage(nil))
      }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let deviceId = peripheral.identifier.uuidString
    peripherals[deviceId] = peripheral
    var manufacturerData: [Int64: FlutterStandardTypedData] = [:]
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
      data.count >= 2
    {
      // The first two bytes are the company ID, little-endian.
      let company = Int64(data[data.startIndex]) | (Int64(data[data.startIndex + 1]) << 8)
      manufacturerData[company] = FlutterStandardTypedData(bytes: data.dropFirst(2))
    }
    var serviceData: [String: FlutterStandardTypedData] = [:]
    if let data = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
      for (uuid, value) in data { serviceData[fullUuid(uuid)] = FlutterStandardTypedData(bytes: value) }
    }
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    events.scanResult(
      ScanResultMessage(
        deviceId: deviceId,
        name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
        rssi: Int64(RSSI.intValue),
        connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
          ?? true,
        txPowerLevel: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber).map {
          Int64($0.intValue)
        },
        serviceUuids: services.map(fullUuid),
        manufacturerData: manufacturerData,
        serviceData: serviceData
      )
    )
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let session = sessions[peripheral.identifier.uuidString] else { return }
    let native = !session.isConnecting
    session.didConnect()
    // A native reconnect nobody in Dart waits for: restore notifications
    // here, since Dart may be suspended.
    if native, let subscribed = wanted[session.deviceId], !subscribed.isEmpty {
      Task { @MainActor in
        _ = try? await session.discoverServices()
        session.resubscribe(Array(subscribed.values))
      }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let deviceId = peripheral.identifier.uuidString
    sessions[deviceId]?.didFailToConnect(error)
    if backgroundMode && wanted[deviceId] != nil {
      // Keep trying in the background, a little later.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.reconnectNatively(deviceId)
      }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    let deviceId = peripheral.identifier.uuidString
    guard let session = sessions[deviceId] else { return }
    let dropped = session.didDisconnect(error)
    if dropped && backgroundMode && wanted[deviceId] != nil {
      reconnectNatively(deviceId)
    }
  }

  #if os(iOS)
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    // iOS relaunched the app for a device event. Take the links back.
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    for peripheral in restored {
      let deviceId = peripheral.identifier.uuidString
      peripherals[deviceId] = peripheral
      let session = PeripheralSession(peripheral: peripheral, events: events)
      sessions[deviceId] = session
      var subscribed: [String: CharacteristicAddressMessage] = [:]
      for address in session.notifyingAddresses() { subscribed[key(of: address)] = address }
      wanted[deviceId] = subscribed
    }
  }
  #endif

  // MARK: Helpers

  private func ensureCentral() -> CBCentralManager {
    if let central = central { return central }
    var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
    #if os(iOS)
    if backgroundMode {
      options[CBCentralManagerOptionRestoreIdentifierKey] = BleHost.restoreIdentifier
    }
    #endif
    let created = CBCentralManager(delegate: self, queue: nil, options: options)
    central = created
    return created
  }

  @MainActor
  private func waitForState() async {
    await withCheckedContinuation { stateWaits.append($0) }
  }

  /// The central manager, once Bluetooth is usable. Waits for the first
  /// state update after creating it.
  @MainActor
  private func requireOn() async throws -> CBCentralManager {
    let central = ensureCentral()
    if central.state == .unknown || central.state == .resetting { await waitForState() }
    switch central.state {
    case .poweredOn: return central
    case .poweredOff: throw poweredOff()
    case .unauthorized: throw permissionDenied()
    case .unsupported: throw unsupported("This device has no Bluetooth LE.")
    default:
      throw VitalBluetoothError(code: "unknown", message: "Bluetooth isn't ready yet.", details: nil)
    }
  }

  private func session(for deviceId: String, central: CBCentralManager) throws
    -> PeripheralSession
  {
    if let session = sessions[deviceId] { return session }
    guard let peripheral = peripheral(for: deviceId, central: central) else {
      throw deviceNotFound(deviceId)
    }
    let session = PeripheralSession(peripheral: peripheral, events: events)
    sessions[deviceId] = session
    return session
  }

  private func peripheral(for deviceId: String, central: CBCentralManager) -> CBPeripheral? {
    if let known = peripherals[deviceId] { return known }
    guard let uuid = UUID(uuidString: deviceId) else { return nil }
    let found = central.retrievePeripherals(withIdentifiers: [uuid]).first
    if let found = found { peripherals[deviceId] = found }
    return found
  }

  private func connected(_ deviceId: String) throws -> PeripheralSession {
    guard let session = sessions[deviceId], session.isConnected else {
      throw notConnected(deviceId)
    }
    return session
  }

  /// Starts a pending connect for a wanted device, if none is running.
  private func reconnectNatively(_ deviceId: String) {
    guard backgroundMode, wanted[deviceId] != nil,
      let central = central, central.state == .poweredOn,
      let session = try? self.session(for: deviceId, central: central),
      !session.isConnected, !session.isConnecting,
      session.peripheral.state != .connecting
    else { return }
    central.connect(session.peripheral, options: nil)
  }

  private func sessionMessage(_ deviceId: String) -> SessionMessage? {
    guard let subscribed = wanted[deviceId] else { return nil }
    let session = sessions[deviceId]
    return SessionMessage(
      deviceId: deviceId,
      name: session?.peripheral.name ?? peripherals[deviceId]?.name,
      connected: session?.isConnected == true,
      subscribed: Array(subscribed.values)
    )
  }

  private func adapterState(of central: CBCentralManager?) -> AdapterStateMessage {
    guard let central = central else {
      switch CBManager.authorization {
      case .denied, .restricted: return .unauthorized
      default: return .unknown
      }
    }
    switch central.state {
    case .poweredOn: return .poweredOn
    case .poweredOff: return .poweredOff
    case .unauthorized: return .unauthorized
    case .unsupported: return .unsupported
    default: return .unknown
    }
  }

  private func permissionStatus() -> PermissionStatusMessage {
    switch CBManager.authorization {
    case .allowedAlways: return .granted
    case .notDetermined: return .denied
    // iOS never asks again; only the Settings app can change it.
    default: return .permanentlyDenied
    }
  }

  private func key(of a: CharacteristicAddressMessage) -> String {
    "\(a.serviceUuid)/\(a.serviceInstance)/\(a.characteristicUuid)/\(a.characteristicInstance)"
  }
}
