package dev.goodluckcy.vital_bluetooth

import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Sends events to Dart from any thread.
 *
 * Bluetooth callbacks arrive on binder threads, but Flutter channels must be
 * used on the main thread. Scan results and notification values are
 * batched: the first value schedules a send on the main thread, and every
 * value that arrives before it runs goes in the same message. This adds no
 * fixed delay but cuts channel traffic a lot for fast sensors.
 *
 * It outlives Flutter engines. With no engine attached, events are dropped,
 * except notification values while [buffering] is on: those are kept (up to
 * [MAX_BUFFERED]) until Dart takes them. A value is also buffered when an
 * engine is attached but no Dart code has claimed its device yet, so values
 * that arrive between the app starting and Dart restoring the device are
 * not lost.
 */
internal class BleEventSender {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val lock = Any()
    private var api: BleFlutterApi? = null
    private val claimed = HashSet<String>()
    private val buffer = ArrayDeque<CharacteristicValueMessage>()
    private var values = ArrayList<CharacteristicValueMessage>()
    private var scanResults = ArrayList<ScanResultMessage>()
    private var valuesScheduled = false
    private var scanScheduled = false

    /** Whether values with nowhere to go are kept. */
    @Volatile
    var buffering = false

    val attached: Boolean get() = synchronized(lock) { api != null }

    fun attach(api: BleFlutterApi) = synchronized(lock) {
        this.api = api
        claimed.clear()
    }

    /** Detaches [api] if it is still the attached one. */
    fun detach(api: BleFlutterApi) = synchronized(lock) {
        if (this.api !== api) return@synchronized
        this.api = null
        claimed.clear()
        scanResults.clear()
        // Values waiting for the flush belong to devices Dart had claimed.
        if (buffering) values.forEach(::keep)
        values.clear()
    }

    /** Dart handles [deviceId] from now on, so its values go out live. */
    fun claim(deviceId: String) = synchronized(lock) { claimed.add(deviceId) }

    fun takeBuffered(): List<CharacteristicValueMessage> = synchronized(lock) {
        buffer.toList().also { buffer.clear() }
    }

    fun adapterState(state: AdapterStateMessage) = onMain {
        send { it.onAdapterStateChanged(state) }
    }

    fun scanResult(result: ScanResultMessage) {
        synchronized(lock) {
            if (api == null) return
            scanResults.add(result)
            if (scanScheduled) return
            scanScheduled = true
        }
        main.post(::flushScanResults)
    }

    fun scanStopped(error: PlatformErrorMessage?) = onMain {
        flushScanResults()
        send { it.onScanStopped(error) }
    }

    fun connectionState(
        deviceId: String,
        state: ConnectionStateMessage,
        error: PlatformErrorMessage? = null,
    ) = onMain {
        // Values received before a drop must reach Dart before the drop.
        flushValues()
        send { it.onConnectionStateChanged(deviceId, state, error) }
    }

    fun value(value: CharacteristicValueMessage) {
        synchronized(lock) {
            if (api == null || value.characteristic.deviceId !in claimed) {
                if (buffering) keep(value)
                return
            }
            values.add(value)
            if (valuesScheduled) return
            valuesScheduled = true
        }
        main.post(::flushValues)
    }

    fun servicesChanged(deviceId: String) = onMain {
        send { it.onServicesChanged(deviceId) }
    }

    fun mtuChanged(deviceId: String, mtu: Int) = onMain {
        send { it.onMtuChanged(deviceId, mtu.toLong()) }
    }

    fun bondState(deviceId: String, state: BondStateMessage) = onMain {
        send { it.onBondStateChanged(deviceId, state) }
    }

    /** Call with [lock] held. */
    private fun keep(value: CharacteristicValueMessage) {
        if (buffer.size >= MAX_BUFFERED) buffer.removeFirst()
        buffer.addLast(value)
    }

    private fun flushScanResults() {
        val batch = synchronized(lock) {
            scanScheduled = false
            if (scanResults.isEmpty()) return
            scanResults.also { scanResults = ArrayList() }
        }
        send { it.onScanResults(batch) }
    }

    private fun flushValues() {
        val batch = synchronized(lock) {
            valuesScheduled = false
            if (values.isEmpty()) return
            values.also { values = ArrayList() }
        }
        send { it.onCharacteristicValues(batch) }
    }

    /**
     * Starts the send right away on the main thread, so events leave in the
     * order they were sent. The reply is ignored: Dart not listening yet is
     * not an error. Without an engine the event is dropped.
     */
    private fun send(block: suspend (BleFlutterApi) -> Unit) {
        val api = synchronized(lock) { api } ?: return
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                block(api)
            } catch (_: VitalBluetoothError) {
            }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    companion object {
        /** About 10 minutes of a 16 Hz sensor, or a few hours of 1 Hz heart rate. */
        const val MAX_BUFFERED = 10_000
    }
}
