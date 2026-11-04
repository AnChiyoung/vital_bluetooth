import CoreBluetooth
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// One device's GATT link.
///
/// The Dart side sends GATT operations one at a time through its queue, so
/// there is a single pending slot. A new call while one is pending means
/// Dart gave up on the old one (timeout); the old one is failed.
///
/// CoreBluetooth has no instance IDs. A service's instance is its index
/// among services with the same UUID, and the same for characteristics in
/// a service, in the order discovery returned them.
final class PeripheralSession: NSObject, CBPeripheralDelegate {
  private enum Kind {
    case discover, read, write, writeWithoutResponse, notify, readDescriptor,
      writeDescriptor, rssi
  }

  private struct Pending {
    let kind: Kind
    let target: AnyObject?
    let continuation: CheckedContinuation<Any?, Error>
  }

  let peripheral: CBPeripheral
  let deviceId: String
  private let events: EventSender
  private var pending: Pending?
  private var discoveryRemaining = 0
  private var connectWaits: [CheckedContinuation<Void, Error>] = []
  private var disconnectWait: CheckedContinuation<Void, Never>?

  init(peripheral: CBPeripheral, events: EventSender) {
    self.peripheral = peripheral
    self.deviceId = peripheral.identifier.uuidString
    self.events = events
    super.init()
    peripheral.delegate = self
  }

  var isConnected: Bool { peripheral.state == .connected }
  var isConnecting: Bool { !connectWaits.isEmpty }
  var isDisconnecting: Bool { disconnectWait != nil }

  // MARK: Connection, driven by BleHost

  /// Waits for the connect BleHost started. Several callers can wait on
  /// the same attempt.
  @MainActor
  func waitForConnect() async throws {
    try await withCheckedThrowingContinuation { connectWaits.append($0) }
  }

  @MainActor
  func waitForDisconnect(timeout: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      disconnectWait?.resume()
      disconnectWait = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.finishDisconnect()
      }
    }
  }

  func didConnect() {
    let waits = connectWaits
    connectWaits = []
    events.connectionState(deviceId, .connected)
    waits.forEach { $0.resume() }
  }

  func didFailToConnect(_ error: Error?) {
    let waits = connectWaits
    connectWaits = []
    let failure =
      error.map { mapError($0, deviceId: deviceId, connecting: true) }
      ?? VitalBluetoothError(
        code: "connectionFailed", message: "Connecting to \(deviceId) failed.", details: nil)
    events.connectionState(deviceId, .disconnected, nil)
    waits.forEach { $0.resume(throwing: failure) }
  }

  /// Returns whether the link dropped on its own (no disconnect() pending).
  @discardableResult
  func didDisconnect(_ error: Error?) -> Bool {
    let expected = disconnectWait != nil
    failPending(notConnected(deviceId))
    let waits = connectWaits
    connectWaits = []
    waits.forEach { $0.resume(throwing: notConnected(deviceId)) }
    events.connectionState(deviceId, .disconnected, expected ? nil : dropMessage(error))
    finishDisconnect()
    return !expected
  }

  /// Fails everything that waits on this link, for example when the adapter
  /// turns off.
  func abort(_ error: VitalBluetoothError) {
    failPending(error)
    let waits = connectWaits
    connectWaits = []
    waits.forEach { $0.resume(throwing: error) }
    finishDisconnect()
  }

  private func finishDisconnect() {
    let wait = disconnectWait
    disconnectWait = nil
    wait?.resume()
  }

  // MARK: GATT

  @MainActor
  func discoverServices() async throws -> [ServiceMessage] {
    _ = try await perform(.discover, target: nil, what: "service discovery") {
      $0.discoverServices(nil)
    }
    return serviceMessages()
  }

  @MainActor
  func read(_ address: CharacteristicAddressMessage) async throws -> FlutterStandardTypedData {
    let characteristic = try find(address)
    let value = try await perform(.read, target: characteristic, what: "read") {
      $0.readValue(for: characteristic)
    }
    return FlutterStandardTypedData(bytes: value as? Data ?? Data())
  }

  @MainActor
  func write(_ address: CharacteristicAddressMessage, _ value: Data, withResponse: Bool) async throws {
    let characteristic = try find(address)
    if withResponse {
      _ = try await perform(.write, target: characteristic, what: "write") {
        $0.writeValue(value, for: characteristic, type: .withResponse)
      }
      return
    }
    // Wait until the stack has room, so fast writers don't lose data.
    if !peripheral.canSendWriteWithoutResponse {
      _ = try await perform(.writeWithoutResponse, target: nil, what: "write") { _ in }
    }
    peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
  }

  @MainActor
  func setNotify(_ address: CharacteristicAddressMessage, _ enable: Bool) async throws {
    let characteristic = try find(address)
    if characteristic.isNotifying == enable { return }
    _ = try await perform(.notify, target: characteristic, what: "notification change") {
      $0.setNotifyValue(enable, for: characteristic)
    }
  }

  @MainActor
  func readDescriptor(_ address: CharacteristicAddressMessage, _ uuid: String) async throws
    -> FlutterStandardTypedData
  {
    let descriptor = try findDescriptor(address, uuid)
    let value = try await perform(.readDescriptor, target: descriptor, what: "descriptor read") {
      $0.readValue(for: descriptor)
    }
    return FlutterStandardTypedData(bytes: descriptorData(value))
  }

  @MainActor
  func writeDescriptor(_ address: CharacteristicAddressMessage, _ uuid: String, _ value: Data)
    async throws
  {
    let descriptor = try findDescriptor(address, uuid)
    if descriptor.uuid.uuidString == CBUUIDClientCharacteristicConfigurationString {
      // CoreBluetooth throws if an app writes the CCCD itself.
      throw unsupported("Use setNotify to turn notifications on or off here.")
    }
    _ = try await perform(.writeDescriptor, target: descriptor, what: "descriptor write") {
      $0.writeValue(value, for: descriptor)
    }
  }

  @MainActor
  func readRssi() async throws -> Int64 {
    let rssi = try await perform(.rssi, target: nil, what: "RSSI read") { $0.readRSSI() }
    return Int64((rssi as? NSNumber)?.intValue ?? 0)
  }

  /// The largest write payload. Apple negotiates the MTU itself.
  func maximumWriteLength(withResponse: Bool) -> Int {
    peripheral.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse)
  }

  /// Turns notifications back on after a native reconnect, without
  /// waiting for each one; failures just leave that one off.
  func resubscribe(_ addresses: [CharacteristicAddressMessage]) {
    for address in addresses {
      if let characteristic = try? find(address), !characteristic.isNotifying {
        peripheral.setNotifyValue(true, for: characteristic)
      }
    }
  }

  /// Characteristics that have notifications on, for state restoration.
  func notifyingAddresses() -> [CharacteristicAddressMessage] {
    var result: [CharacteristicAddressMessage] = []
    for service in peripheral.services ?? [] {
      for characteristic in service.characteristics ?? [] where characteristic.isNotifying {
        if let address = address(of: characteristic) { result.append(address) }
      }
    }
    return result
  }

  // MARK: Pending operations

  @MainActor
  private func perform(
    _ kind: Kind,
    target: AnyObject?,
    what: String,
    start: @escaping (CBPeripheral) -> Void
  ) async throws -> Any? {
    guard isConnected else { throw notConnected(deviceId) }
    return try await withCheckedThrowingContinuation { continuation in
      failPending(VitalBluetoothError(code: "unknown", message: "Replaced by a newer operation.", details: nil))
      pending = Pending(kind: kind, target: target, continuation: continuation)
      start(peripheral)
    }
  }

  private func finish(_ kind: Kind, target: AnyObject?, error: Error?, value: Any? = nil) {
    guard let current = pending, current.kind == kind,
      current.target == nil || current.target === target
    else { return }
    pending = nil
    if let error = error {
      current.continuation.resume(throwing: mapError(error, deviceId: deviceId))
    } else {
      current.continuation.resume(returning: value)
    }
  }

  private func failPending(_ error: VitalBluetoothError) {
    let current = pending
    pending = nil
    discoveryRemaining = 0
    current?.continuation.resume(throwing: error)
  }

  // MARK: CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      finish(.discover, target: nil, error: error)
      return
    }
    let services = peripheral.services ?? []
    discoveryRemaining = services.count
    if services.isEmpty { finish(.discover, target: nil, error: nil) }
    services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error = error {
      finish(.discover, target: nil, error: error)
      return
    }
    let characteristics = service.characteristics ?? []
    // One step for the service is done; each characteristic adds one for
    // its descriptors.
    discoveryRemaining += characteristics.count - 1
    characteristics.forEach { peripheral.discoverDescriptors(for: $0) }
    discoveryStepDone()
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverDescriptorsFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // A characteristic whose descriptors can't be read is still usable.
    discoveryRemaining -= 1
    discoveryStepDone()
  }

  private func discoveryStepDone() {
    if discoveryRemaining <= 0 { finish(.discover, target: nil, error: nil) }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let current = pending, current.kind == .read, current.target === characteristic {
      finish(.read, target: characteristic, error: error, value: characteristic.value ?? Data())
      return
    }
    // Anything else is a notification or indication.
    guard error == nil, let address = address(of: characteristic) else { return }
    events.value(
      CharacteristicValueMessage(
        characteristic: address,
        value: FlutterStandardTypedData(bytes: characteristic.value ?? Data()),
        timestampMicros: nowMicros()
      )
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    finish(.write, target: characteristic, error: error)
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    finish(.writeWithoutResponse, target: nil, error: nil)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    finish(.notify, target: characteristic, error: error)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    finish(.readDescriptor, target: descriptor, error: error, value: descriptor.value)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    finish(.writeDescriptor, target: descriptor, error: error)
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    finish(.rssi, target: nil, error: error, value: RSSI)
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    events.servicesChanged(deviceId)
  }

  // MARK: Addressing

  private func serviceMessages() -> [ServiceMessage] {
    let services = peripheral.services ?? []
    return services.map { service in
      let characteristics = service.characteristics ?? []
      return ServiceMessage(
        uuid: fullUuid(service.uuid),
        instance: Int64(instance(of: service, in: services)),
        isPrimary: service.isPrimary,
        characteristics: characteristics.map { c in
          let p = c.properties
          return CharacteristicMessage(
            uuid: fullUuid(c.uuid),
            instance: Int64(instance(of: c, in: characteristics)),
            properties: CharacteristicPropertiesMessage(
              broadcast: p.contains(.broadcast),
              read: p.contains(.read),
              writeWithoutResponse: p.contains(.writeWithoutResponse),
              write: p.contains(.write),
              notify: p.contains(.notify),
              indicate: p.contains(.indicate),
              authenticatedSignedWrites: p.contains(.authenticatedSignedWrites),
              extendedProperties: p.contains(.extendedProperties)
            ),
            descriptors: (c.descriptors ?? []).map { DescriptorMessage(uuid: fullUuid($0.uuid)) }
          )
        },
        includedServices: (service.includedServices ?? []).map { fullUuid($0.uuid) }
      )
    }
  }

  private func instance(of service: CBService, in services: [CBService]) -> Int {
    services.filter { $0.uuid == service.uuid }.firstIndex { $0 === service } ?? 0
  }

  private func instance(of characteristic: CBCharacteristic, in list: [CBCharacteristic]) -> Int {
    list.filter { $0.uuid == characteristic.uuid }.firstIndex { $0 === characteristic } ?? 0
  }

  private func address(of characteristic: CBCharacteristic) -> CharacteristicAddressMessage? {
    guard let service = characteristic.service else { return nil }
    let services = peripheral.services ?? []
    return CharacteristicAddressMessage(
      deviceId: deviceId,
      serviceUuid: fullUuid(service.uuid),
      serviceInstance: Int64(instance(of: service, in: services)),
      characteristicUuid: fullUuid(characteristic.uuid),
      characteristicInstance: Int64(instance(of: characteristic, in: service.characteristics ?? []))
    )
  }

  private func find(_ address: CharacteristicAddressMessage) throws -> CBCharacteristic {
    guard isConnected else { throw notConnected(deviceId) }
    let serviceUuid = CBUUID(string: address.serviceUuid)
    let services = (peripheral.services ?? []).filter { $0.uuid == serviceUuid }
    guard Int(address.serviceInstance) < services.count else {
      throw attributeNotFound(address.serviceUuid)
    }
    let service = services[Int(address.serviceInstance)]
    let characteristicUuid = CBUUID(string: address.characteristicUuid)
    let characteristics = (service.characteristics ?? []).filter { $0.uuid == characteristicUuid }
    guard Int(address.characteristicInstance) < characteristics.count else {
      throw attributeNotFound(address.characteristicUuid)
    }
    return characteristics[Int(address.characteristicInstance)]
  }

  private func findDescriptor(_ address: CharacteristicAddressMessage, _ uuid: String) throws
    -> CBDescriptor
  {
    let target = CBUUID(string: uuid)
    guard let descriptor = try find(address).descriptors?.first(where: { $0.uuid == target }) else {
      throw attributeNotFound(uuid)
    }
    return descriptor
  }

  /// Descriptor values come back as NSData, NSNumber or NSString depending
  /// on the descriptor.
  private func descriptorData(_ value: Any?) -> Data {
    switch value {
    case let data as Data:
      return data
    case let number as NSNumber:
      var raw = number.uint16Value.littleEndian
      return Data(bytes: &raw, count: 2)
    case let string as String:
      return Data(string.utf8)
    default:
      return Data()
    }
  }
}
