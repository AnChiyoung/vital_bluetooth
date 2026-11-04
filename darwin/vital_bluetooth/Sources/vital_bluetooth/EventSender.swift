import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Sends events to Dart. Everything here runs on the main thread, because
/// the central manager delivers its callbacks on the main queue.
///
/// Scan results and notification values are batched: the first value
/// schedules a send on the next main-loop turn, and every value that
/// arrives before it goes in the same message.
///
/// Values for a device that no Dart code has claimed yet are kept while
/// [buffering] is on (background mode), up to [maxBuffered], for
/// takeBufferedValues(). That covers the app being relaunched in the
/// background by state restoration before Dart has restored the device.
final class EventSender {
  static let maxBuffered = 10_000

  private var api: BleFlutterApi?
  private var claimed = Set<String>()
  private var buffer: [CharacteristicValueMessage] = []
  private var values: [CharacteristicValueMessage] = []
  private var scanResults: [ScanResultMessage] = []
  private var valuesScheduled = false
  private var scanScheduled = false

  var buffering = false

  init(api: BleFlutterApi) {
    self.api = api
  }

  func claim(_ deviceId: String) {
    claimed.insert(deviceId)
  }

  func takeBuffered() -> [CharacteristicValueMessage] {
    defer { buffer.removeAll() }
    return buffer
  }

  func adapterState(_ state: AdapterStateMessage) {
    send { try await $0.onAdapterStateChanged(state: state) }
  }

  func scanResult(_ result: ScanResultMessage) {
    scanResults.append(result)
    if scanScheduled { return }
    scanScheduled = true
    DispatchQueue.main.async { self.flushScanResults() }
  }

  func scanStopped(_ error: PlatformErrorMessage?) {
    flushScanResults()
    send { try await $0.onScanStopped(error: error) }
  }

  func connectionState(
    _ deviceId: String,
    _ state: ConnectionStateMessage,
    _ error: PlatformErrorMessage? = nil
  ) {
    // Values received before a drop must reach Dart before the drop.
    flushValues()
    send { try await $0.onConnectionStateChanged(deviceId: deviceId, state: state, error: error) }
  }

  func value(_ value: CharacteristicValueMessage) {
    guard claimed.contains(value.characteristic.deviceId) else {
      if buffering { keep(value) }
      return
    }
    values.append(value)
    if valuesScheduled { return }
    valuesScheduled = true
    DispatchQueue.main.async { self.flushValues() }
  }

  func servicesChanged(_ deviceId: String) {
    send { try await $0.onServicesChanged(deviceId: deviceId) }
  }

  func mtuChanged(_ deviceId: String, _ mtu: Int) {
    send { try await $0.onMtuChanged(deviceId: deviceId, mtu: Int64(mtu)) }
  }

  private func keep(_ value: CharacteristicValueMessage) {
    if buffer.count >= EventSender.maxBuffered { buffer.removeFirst() }
    buffer.append(value)
  }

  private func flushScanResults() {
    scanScheduled = false
    if scanResults.isEmpty { return }
    let batch = scanResults
    scanResults = []
    send { try await $0.onScanResults(results: batch) }
  }

  private func flushValues() {
    valuesScheduled = false
    if values.isEmpty { return }
    let batch = values
    values = []
    send { try await $0.onCharacteristicValues(values: batch) }
  }

  /// Dart not listening yet is not an error, so failures are ignored.
  private func send(_ block: @escaping @MainActor (BleFlutterApi) async throws -> Void) {
    guard let api = api else { return }
    Task { @MainActor in try? await block(api) }
  }
}
