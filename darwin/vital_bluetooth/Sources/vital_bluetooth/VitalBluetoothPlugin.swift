#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Registers the Pigeon host APIs with the Flutter engine.
public class VitalBluetoothPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    BleHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: BleHost(events: BleFlutterApi(binaryMessenger: messenger))
    )
    ClassicHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: ClassicHost(events: ClassicFlutterApi(binaryMessenger: messenger))
    )
  }
}
