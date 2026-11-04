import CoreBluetooth
import Foundation

// Errors use the codes listed at the top of pigeons/messages.dart.

func unsupported(_ message: String) -> VitalBluetoothError {
  VitalBluetoothError(code: "unsupported", message: message, details: nil)
}

func notImplemented() -> VitalBluetoothError {
  unsupported("Not implemented on this platform yet.")
}

func poweredOff() -> VitalBluetoothError {
  VitalBluetoothError(code: "poweredOff", message: "Bluetooth is off.", details: nil)
}

func permissionDenied() -> VitalBluetoothError {
  VitalBluetoothError(
    code: "permissionDenied",
    message: "The app isn't allowed to use Bluetooth.",
    details: ["bluetooth"]
  )
}

func deviceNotFound(_ deviceId: String) -> VitalBluetoothError {
  VitalBluetoothError(
    code: "deviceNotFound",
    message: "No known device with ID \(deviceId).",
    details: nil
  )
}

func notConnected(_ deviceId: String) -> VitalBluetoothError {
  VitalBluetoothError(code: "notConnected", message: "\(deviceId) is not connected.", details: nil)
}

func attributeNotFound(_ uuid: String) -> VitalBluetoothError {
  VitalBluetoothError(code: "attributeNotFound", message: "\(uuid) was not found.", details: uuid)
}

func refused(_ what: String) -> VitalBluetoothError {
  VitalBluetoothError(code: "unknown", message: "The system refused the \(what).", details: nil)
}

/// Turns a CoreBluetooth error into the shared codes. ATT errors keep their
/// status so Dart can tell, for example, that pairing is needed.
func mapError(_ error: Error, deviceId: String, connecting: Bool = false) -> VitalBluetoothError {
  let nsError = error as NSError
  if nsError.domain == CBATTErrorDomain {
    return VitalBluetoothError(
      code: "gattError",
      message: nsError.localizedDescription,
      details: nsError.code
    )
  }
  if connecting {
    return VitalBluetoothError(
      code: "connectionFailed",
      message: "Connecting to \(deviceId) failed: \(nsError.localizedDescription)",
      details: String(nsError.code)
    )
  }
  if nsError.domain == CBErrorDomain,
    let code = CBError.Code(rawValue: nsError.code),
    code == .peripheralDisconnected || code == .connectionTimeout || code == .notConnected
  {
    return notConnected(deviceId)
  }
  return VitalBluetoothError(
    code: "unknown",
    message: nsError.localizedDescription,
    details: String(nsError.code)
  )
}

/// The platform error sent with a disconnected event.
func dropMessage(_ error: Error?) -> PlatformErrorMessage {
  let nsError = error as NSError?
  return PlatformErrorMessage(
    code: "notConnected",
    message: nsError?.localizedDescription ?? "The link dropped.",
    platformCode: nsError.map { String($0.code) }
  )
}

/// CoreBluetooth shortens Bluetooth SIG UUIDs ("180D"); the contract wants
/// the full lowercase form.
func fullUuid(_ uuid: CBUUID) -> String {
  let s = uuid.uuidString.lowercased()
  switch s.count {
  case 4: return "0000\(s)-0000-1000-8000-00805f9b34fb"
  case 8: return "\(s)-0000-1000-8000-00805f9b34fb"
  default: return s
  }
}

func nowMicros() -> Int64 {
  Int64(Date().timeIntervalSince1970 * 1_000_000)
}
