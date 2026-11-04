package dev.goodluckcy.vital_bluetooth

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * Registers the Pigeon host APIs with the Flutter engine.
 *
 * The Activity is needed only for the permission prompts and the
 * "turn Bluetooth on" prompt. The BLE host itself is shared by the whole
 * process; each engine only attaches to it.
 */
class VitalBluetoothPlugin : FlutterPlugin, ActivityAware {
    private var ble: BleHost? = null
    private var events: BleFlutterApi? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        val ble = BleHost.get(binding.applicationContext)
        val events = BleFlutterApi(messenger)
        ble.attachEngine(events)
        this.ble = ble
        this.events = events
        BleHostApi.setUp(messenger, ble)
        ClassicHostApi.setUp(messenger, ClassicHost(ClassicFlutterApi(messenger)))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        BleHostApi.setUp(messenger, null)
        ClassicHostApi.setUp(messenger, null)
        events?.let { ble?.detachEngine(it) }
        events = null
        ble = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        val ble = ble ?: return
        activityBinding = binding
        binding.addRequestPermissionsResultListener(ble.permissionListener)
        binding.addActivityResultListener(ble.activityResultListener)
        ble.attachActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        val ble = ble
        activityBinding?.let { binding ->
            if (ble != null) {
                binding.removeRequestPermissionsResultListener(ble.permissionListener)
                binding.removeActivityResultListener(ble.activityResultListener)
            }
        }
        activityBinding = null
        ble?.attachActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
}
