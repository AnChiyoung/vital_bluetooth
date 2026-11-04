#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// iOS and macOS side of ClassicHostApi.
///
/// iOS can't use Classic without MFi, so every call throws `unsupported`.
/// macOS will use IOBluetooth; only the API shape is in place so far.
final class ClassicHost: ClassicHostApi {
  private let events: ClassicFlutterApi

  init(events: ClassicFlutterApi) {
    self.events = events
  }

  func getBondedDevices() async throws -> [ClassicDeviceMessage] { throw notSupportedHere() }
  func startDiscovery() async throws { throw notSupportedHere() }
  func stopDiscovery() async throws { throw notSupportedHere() }

  func connect(deviceId: String, serviceUuid: String, secure: Bool) async throws {
    throw notSupportedHere()
  }

  func disconnect(deviceId: String) async throws { throw notSupportedHere() }

  func write(deviceId: String, data: FlutterStandardTypedData) async throws {
    throw notSupportedHere()
  }

  private func notSupportedHere() -> VitalBluetoothError {
    #if os(iOS)
    return unsupported("Bluetooth Classic needs MFi on iOS.")
    #else
    return notImplemented()
    #endif
  }
}
