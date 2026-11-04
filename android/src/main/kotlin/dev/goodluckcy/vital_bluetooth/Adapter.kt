package dev.goodluckcy.vital_bluetooth

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred

/**
 * The phone's Bluetooth adapter: its state, state changes, and the system
 * prompt that turns it on.
 */
internal class Adapter(
    private val context: Context,
    private val onStateChanged: (AdapterStateMessage) -> Unit,
) : PluginRegistry.ActivityResultListener {

    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?

    /** Null when the phone has no Bluetooth at all. */
    val bluetooth: BluetoothAdapter? = manager?.adapter

    val bluetoothManager: BluetoothManager? = manager

    val hasBle: Boolean =
        bluetooth != null &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    private var activity: Activity? = null
    private var pendingTurnOn: CompletableDeferred<Unit>? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            onStateChanged(map(state))
            if (state == BluetoothAdapter.STATE_ON) {
                pendingTurnOn?.complete(Unit)
                pendingTurnOn = null
            }
        }
    }

    fun start() {
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    fun stop() {
        context.unregisterReceiver(receiver)
        pendingTurnOn?.completeExceptionally(poweredOff("The plugin was detached."))
        pendingTurnOn = null
    }

    fun attach(activity: Activity?) {
        this.activity = activity
    }

    val state: AdapterStateMessage
        get() {
            val bluetooth = bluetooth ?: return AdapterStateMessage.UNSUPPORTED
            if (!hasBle) return AdapterStateMessage.UNSUPPORTED
            return map(bluetooth.state)
        }

    val isOn: Boolean get() = bluetooth?.isEnabled == true

    /** Throws `unsupported` or `poweredOff` unless the adapter is on. */
    fun requireOn() {
        if (!hasBle) throw VitalBluetoothError("unsupported", "This phone has no Bluetooth LE.")
        if (!isOn) throw poweredOff("Bluetooth is off.")
    }

    /**
     * Shows the system prompt that asks the user to turn Bluetooth on, and
     * completes once it is on. Throws `poweredOff` if the user says no.
     */
    @SuppressLint("MissingPermission") // Checked by the caller.
    suspend fun turnOn() {
        if (!hasBle) throw VitalBluetoothError("unsupported", "This phone has no Bluetooth LE.")
        if (isOn) return
        val activity = activity ?: throw VitalBluetoothError(
            "unknown",
            "Bluetooth can only be turned on while an Activity is attached.",
        )
        pendingTurnOn?.let { return it.await() }
        val deferred = CompletableDeferred<Unit>()
        pendingTurnOn = deferred
        activity.startActivityForResult(
            Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
            REQUEST_ENABLE,
        )
        deferred.await()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_ENABLE) return false
        if (resultCode != Activity.RESULT_OK) {
            pendingTurnOn?.completeExceptionally(poweredOff("The user didn't turn Bluetooth on."))
            pendingTurnOn = null
        } else if (isOn) {
            pendingTurnOn?.complete(Unit)
            pendingTurnOn = null
        }
        // Otherwise the state receiver completes it once the adapter is on.
        return true
    }

    private fun map(state: Int) = when (state) {
        BluetoothAdapter.STATE_OFF -> AdapterStateMessage.POWERED_OFF
        BluetoothAdapter.STATE_TURNING_ON -> AdapterStateMessage.TURNING_ON
        BluetoothAdapter.STATE_ON -> AdapterStateMessage.POWERED_ON
        BluetoothAdapter.STATE_TURNING_OFF -> AdapterStateMessage.TURNING_OFF
        else -> AdapterStateMessage.UNKNOWN
    }

    private companion object {
        const val REQUEST_ENABLE = 0xB1F
    }
}

internal fun poweredOff(message: String) = VitalBluetoothError("poweredOff", message)
