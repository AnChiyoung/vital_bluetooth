import CoreBluetooth
import FlutterMacOS
import XCTest

// If your plugin has been explicitly set to "type: .dynamic" in the Package.swift,
// you will need to add your plugin as a dependency of RunnerTests within Xcode.

@testable import vital_bluetooth

class RunnerTests: XCTestCase {

  func testShortUuidsBecomeFullLowercase() {
    XCTAssertEqual(fullUuid(CBUUID(string: "180D")), "0000180d-0000-1000-8000-00805f9b34fb")
    XCTAssertEqual(
      fullUuid(CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")),
      "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
  }

  func testAttErrorsKeepTheirStatus() {
    let error = NSError(domain: CBATTErrorDomain, code: 5)
    let mapped = mapError(error, deviceId: "AA")
    XCTAssertEqual(mapped.code, "gattError")
    XCTAssertEqual(mapped.details as? Int, 5)
  }

  func testConnectFailuresMapToConnectionFailed() {
    let error = NSError(domain: CBErrorDomain, code: CBError.Code.connectionFailed.rawValue)
    XCTAssertEqual(mapError(error, deviceId: "AA", connecting: true).code, "connectionFailed")
  }
}
