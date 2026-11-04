package dev.goodluckcy.vital_bluetooth

import android.annotation.SuppressLint
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log

/**
 * BLE scanning.
 *
 * Android silently stops delivering results to an app that starts more than
 * five scans in 30 seconds. The scanner keeps one scan running and logs a
 * warning when the app comes close to that limit.
 */
@SuppressLint("MissingPermission") // BleHost checks permissions first.
internal class Scanner(
    private val adapter: Adapter,
    private val events: BleEventSender,
) {
    private var callback: ScanCallback? = null
    private val seen = HashSet<String>()
    private var allowDuplicates = false
    private val recentStarts = ArrayDeque<Long>()

    val isScanning: Boolean get() = callback != null

    fun start(settings: ScanSettingsMessage) {
        stop()
        val scanner = adapter.bluetooth?.bluetoothLeScanner
            ?: throw poweredOff("Bluetooth is off.")
        noteStart()

        seen.clear()
        allowDuplicates = settings.allowDuplicates
        val filters = settings.serviceUuids.map {
            ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(it)).build()
        }
        val scanSettings = ScanSettings.Builder()
            .setScanMode(
                when (settings.mode) {
                    ScanModeMessage.LOW_POWER -> ScanSettings.SCAN_MODE_LOW_POWER
                    ScanModeMessage.BALANCED -> ScanSettings.SCAN_MODE_BALANCED
                    ScanModeMessage.LOW_LATENCY -> ScanSettings.SCAN_MODE_LOW_LATENCY
                },
            )
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) setLegacy(false)
            }
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = report(result)

            override fun onBatchScanResults(results: MutableList<ScanResult>) =
                results.forEach(::report)

            override fun onScanFailed(errorCode: Int) {
                if (this@Scanner.callback !== this) return
                this@Scanner.callback = null
                events.scanStopped(
                    PlatformErrorMessage(
                        code = if (errorCode == SCAN_FAILED_FEATURE_UNSUPPORTED) "unsupported" else "unknown",
                        message = "Scan failed (${scanFailureName(errorCode)}).",
                        platformCode = errorCode.toString(),
                    ),
                )
            }
        }
        this.callback = callback
        scanner.startScan(filters, scanSettings, callback)
    }

    fun stop() {
        val callback = callback ?: return
        this.callback = null
        // Stopping fails when the adapter is already off; the scan is gone
        // either way.
        runCatching { adapter.bluetooth?.bluetoothLeScanner?.stopScan(callback) }
    }

    /** Called when the adapter turns off, which ends every scan. */
    fun onAdapterOff() {
        if (callback == null) return
        callback = null
        events.scanStopped(PlatformErrorMessage(code = "poweredOff", message = "Bluetooth turned off."))
    }

    private fun report(result: ScanResult) {
        val id = result.device.address
        if (!allowDuplicates && !seen.add(id)) return
        events.scanResult(result.toMessage())
    }

    private fun noteStart() {
        val now = SystemClock.elapsedRealtime()
        while (recentStarts.isNotEmpty() && now - recentStarts.first() > 30_000) {
            recentStarts.removeFirst()
        }
        recentStarts.addLast(now)
        if (recentStarts.size > 5) {
            Log.w(
                TAG,
                "Started ${recentStarts.size} scans in 30 seconds. Android stops " +
                    "delivering results after 5; keep one scan running instead.",
            )
        }
    }

    private fun scanFailureName(code: Int) = when (code) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "already started"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "app registration failed"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "internal error"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "feature unsupported"
        5 -> "out of hardware resources"
        6 -> "scanning too frequently"
        else -> "code $code"
    }
}

@SuppressLint("MissingPermission")
internal fun ScanResult.toMessage(): ScanResultMessage {
    val record = scanRecord
    val manufacturer = HashMap<Long, ByteArray>()
    record?.manufacturerSpecificData?.let { data ->
        for (i in 0 until data.size()) manufacturer[data.keyAt(i).toLong()] = data.valueAt(i)
    }
    val serviceData = HashMap<String, ByteArray>()
    record?.serviceData?.forEach { (uuid, bytes) -> serviceData[uuid.toString().lowercase()] = bytes }
    val txPower = record?.txPowerLevel?.takeIf { it != Int.MIN_VALUE }
    // The device name needs BLUETOOTH_CONNECT on Android 12+; the
    // advertised name doesn't.
    val name = record?.deviceName ?: runCatching { device.name }.getOrNull()
    return ScanResultMessage(
        deviceId = device.address,
        name = name,
        rssi = rssi.toLong(),
        connectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) isConnectable else true,
        txPowerLevel = txPower?.toLong(),
        serviceUuids = record?.serviceUuids?.map { it.toString().lowercase() } ?: emptyList(),
        manufacturerData = manufacturer,
        serviceData = serviceData,
    )
}

internal const val TAG = "VitalBluetooth"
