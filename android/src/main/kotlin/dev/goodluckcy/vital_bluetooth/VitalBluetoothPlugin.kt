package dev.goodluckcy.vital_bluetooth

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Registers the Pigeon host APIs with the Flutter engine. */
class VitalBluetoothPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        BleHostApi.setUp(messenger, BleHost(BleFlutterApi(messenger)))
        ClassicHostApi.setUp(messenger, ClassicHost(ClassicFlutterApi(messenger)))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        BleHostApi.setUp(messenger, null)
        ClassicHostApi.setUp(messenger, null)
    }
}
