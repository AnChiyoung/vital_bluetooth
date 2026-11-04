package dev.goodluckcy.vital_bluetooth

import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Sends events to Dart from any thread.
 *
 * Bluetooth callbacks arrive on binder threads, but Flutter channels must be
 * used on the main thread. Scan results and notification values are
 * batched: the first value schedules a send on the main thread, and every
 * value that arrives before it runs goes in the same message. This adds no
 * fixed delay but cuts channel traffic a lot for fast sensors.
 */
internal class BleEventSender(private val api: BleFlutterApi) {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val lock = Any()
    private var values = ArrayList<CharacteristicValueMessage>()
    private var scanResults = ArrayList<ScanResultMessage>()
    private var valuesScheduled = false
    private var scanScheduled = false

    fun adapterState(state: AdapterStateMessage) = onMain {
        send { api.onAdapterStateChanged(state) }
    }

    fun scanResult(result: ScanResultMessage) {
        synchronized(lock) {
            scanResults.add(result)
            if (scanScheduled) return
            scanScheduled = true
        }
        main.post(::flushScanResults)
    }

    fun scanStopped(error: PlatformErrorMessage?) = onMain {
        flushScanResults()
        send { api.onScanStopped(error) }
    }

    fun connectionState(
        deviceId: String,
        state: ConnectionStateMessage,
        error: PlatformErrorMessage? = null,
    ) = onMain {
        // Values received before a drop must reach Dart before the drop.
        flushValues()
        send { api.onConnectionStateChanged(deviceId, state, error) }
    }

    fun value(value: CharacteristicValueMessage) {
        synchronized(lock) {
            values.add(value)
            if (valuesScheduled) return
            valuesScheduled = true
        }
        main.post(::flushValues)
    }

    fun servicesChanged(deviceId: String) = onMain {
        send { api.onServicesChanged(deviceId) }
    }

    fun mtuChanged(deviceId: String, mtu: Int) = onMain {
        send { api.onMtuChanged(deviceId, mtu.toLong()) }
    }

    fun bondState(deviceId: String, state: BondStateMessage) = onMain {
        send { api.onBondStateChanged(deviceId, state) }
    }

    fun dispose() {
        main.removeCallbacksAndMessages(null)
        scope.cancel()
    }

    private fun flushScanResults() {
        val batch = synchronized(lock) {
            scanScheduled = false
            if (scanResults.isEmpty()) return
            scanResults.also { scanResults = ArrayList() }
        }
        send { api.onScanResults(batch) }
    }

    private fun flushValues() {
        val batch = synchronized(lock) {
            valuesScheduled = false
            if (values.isEmpty()) return
            values.also { values = ArrayList() }
        }
        send { api.onCharacteristicValues(batch) }
    }

    /**
     * Starts the send right away on the main thread, so events leave in the
     * order they were sent. The reply is ignored: Dart not listening yet is
     * not an error.
     */
    private fun send(block: suspend () -> Unit) {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                block()
            } catch (_: VitalBluetoothError) {
            }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }
}
