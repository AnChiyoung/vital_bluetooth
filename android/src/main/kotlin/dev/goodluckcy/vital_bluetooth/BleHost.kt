package dev.goodluckcy.vital_bluetooth

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Android side of [BleHostApi].
 *
 * Every call runs on the main thread (Pigeon starts the coroutines there).
 * Each connected device has its own [GattSession].
 *
 * There is one per process, not one per Flutter engine, so links can outlive
 * the engine. Without background mode, an engine going away closes every
 * link as before. With it, links stay up, a dropped link is reconnected
 * here in native code, notifications are turned back on, and values are
 * buffered until Dart takes them.
 */
@SuppressLint("MissingPermission") // Every entry point checks permissions first.
internal class BleHost private constructor(private val context: Context) : BleHostApi {
    private val events = BleEventSender()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val permissions = Permissions(context)
    private val adapter = Adapter(context, ::onAdapterStateChanged)
    private val scanner = Scanner(adapter, events)
    private val sessions = HashMap<String, GattSession>()
    private val pendingBonds = HashMap<String, CompletableDeferred<Unit>>()

    // Devices Dart asked to connect and has not disconnected, with the
    // characteristics it turned notifications on for, by address key.
    private val wanted = HashMap<String, LinkedHashMap<String, CharacteristicAddressMessage>>()
    private val reconnects = HashMap<String, Job>()
    private var backgroundMode = false

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = intent.bluetoothDevice() ?: return
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            val previous = intent.getIntExtra(
                BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE,
                BluetoothDevice.ERROR,
            )
            events.bondState(device.address, mapBondState(state))
            when {
                state == BluetoothDevice.BOND_BONDED ->
                    pendingBonds.remove(device.address)?.complete(Unit)
                state == BluetoothDevice.BOND_NONE && previous == BluetoothDevice.BOND_BONDING -> {
                    val reason = intent.getIntExtra(EXTRA_REASON, -1)
                    pendingBonds.remove(device.address)?.completeExceptionally(
                        VitalBluetoothError(
                            "bondingFailed",
                            "Pairing with ${device.address} failed (reason $reason).",
                            reason.toString(),
                        ),
                    )
                }
            }
        }
    }

    // --- Lifecycle, called by VitalBluetoothPlugin ---

    init {
        adapter.start()
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(bondReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(bondReceiver, filter)
        }
    }

    fun attachEngine(api: BleFlutterApi) {
        events.attach(api)
        // Dart reconnects from here on. Links still being restored are
        // handed back: Dart sees them as not connected and runs its own
        // reconnect policy.
        reconnects.values.forEach { it.cancel() }
        reconnects.clear()
    }

    fun detachEngine(api: BleFlutterApi) {
        events.detach(api)
        if (events.attached) return // Another engine took over.
        scanner.stop()
        pendingBonds.values.forEach {
            it.completeExceptionally(VitalBluetoothError("unknown", "The plugin was detached."))
        }
        pendingBonds.clear()
        if (!backgroundMode) {
            wanted.clear()
            sessions.values.toList().forEach { it.release() }
            sessions.clear()
            return
        }
        // Keep what is up, and take over links Dart was still restoring.
        for (deviceId in wanted.keys.toList()) {
            val session = sessions[deviceId]
            if (session?.isConnected == true) continue
            session?.release()
            reconnectNatively(deviceId)
        }
    }

    fun attachActivity(activity: Activity?) {
        permissions.attach(activity)
        adapter.attach(activity)
    }

    val permissionListener get() = permissions
    val activityResultListener get() = adapter

    /** Called by [VitalBluetoothService] when Android refused to start it. */
    fun onServiceFailed() {
        if (!backgroundMode) return
        backgroundMode = false
        events.buffering = false
        Log.e(TAG, "Background mode stopped: the foreground service could not start.")
    }

    // --- Background mode ---

    override suspend fun enableBackgroundMode(notification: BackgroundNotificationMessage) {
        // Android 14 only starts a connectedDevice service with this granted.
        permissions.require(connectPermissions())
        permissions.requestNotifications()
        try {
            VitalBluetoothService.start(context, notification.title, notification.text)
        } catch (e: IllegalStateException) {
            // Android 12+ refuses to start it while the app is in the background.
            throw VitalBluetoothError(
                "unknown",
                "Background mode can only be turned on while the app is in the foreground.",
                e.message,
            )
        }
        backgroundMode = true
        events.buffering = true
    }

    override fun disableBackgroundMode() {
        backgroundMode = false
        events.buffering = false
        reconnects.values.forEach { it.cancel() }
        reconnects.clear()
        VitalBluetoothService.stop(context)
    }

    override fun isBackgroundModeEnabled(): Boolean = backgroundMode

    override fun getSession(deviceId: String): SessionMessage? {
        events.claim(deviceId)
        val subscribed = wanted[deviceId] ?: return null
        return SessionMessage(
            deviceId = deviceId,
            connected = sessions[deviceId]?.isConnected == true,
            subscribed = subscribed.values.toList(),
        )
    }

    override fun getSessions(): List<SessionMessage> = wanted.map { (deviceId, subscribed) ->
        SessionMessage(
            deviceId = deviceId,
            connected = sessions[deviceId]?.isConnected == true,
            subscribed = subscribed.values.toList(),
        )
    }

    override fun takeBufferedValues(): List<CharacteristicValueMessage> = events.takeBuffered()

    /**
     * Restores [deviceId]'s link without Dart. Android's autoConnect waits
     * for the device to come back in range at no battery cost, so the
     * attempt itself has no time limit; failures retry with backoff.
     */
    private fun reconnectNatively(deviceId: String) {
        if (reconnects.containsKey(deviceId)) return
        val job = scope.launch {
            var backoff = RECONNECT_MIN_DELAY_MS
            while (backgroundMode && !events.attached && deviceId in wanted) {
                val session = try {
                    newSession(deviceId)
                } catch (e: VitalBluetoothError) {
                    Log.w(TAG, "Can't reconnect $deviceId: ${e.message}")
                    break
                }
                try {
                    session.connect(autoConnect = true)
                    session.discoverServices()
                    for (address in wanted[deviceId]?.values?.toList().orEmpty()) {
                        runCatching { session.setNotify(address, true) }
                    }
                    Log.i(TAG, "Reconnected $deviceId in the background.")
                    break
                } catch (e: CancellationException) {
                    if (!session.isConnected) session.release()
                    throw e
                } catch (e: Exception) {
                    session.release()
                    delay(backoff)
                    backoff = minOf(backoff * 2, RECONNECT_MAX_DELAY_MS)
                }
            }
        }
        reconnects[deviceId] = job
        job.invokeOnCompletion { if (reconnects[deviceId] === job) reconnects.remove(deviceId) }
    }

    private fun newSession(deviceId: String): GattSession {
        adapter.requireOn()
        permissions.require(connectPermissions())
        return GattSession(deviceId, context, remoteDevice(deviceId), events, ::onSessionClosed)
            .also { sessions[deviceId] = it }
    }

    // --- Adapter and permissions ---

    override fun getCapabilities() = CapabilitiesMessage(
        ble = adapter.hasBle,
        classic = adapter.bluetooth != null,
        bonding = true,
        connectionPriority = true,
        phy = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            adapter.bluetooth?.isLe2MPhySupported == true,
    )

    override fun getAdapterState(): AdapterStateMessage = adapter.state

    override suspend fun turnOn() {
        permissions.require(connectPermissions())
        adapter.turnOn()
    }

    override fun getPermissionStatus(): PermissionStatusMessage = permissions.status()

    override suspend fun requestPermissions(): PermissionStatusMessage = permissions.request()

    // --- Scanning ---

    override suspend fun startScan(settings: ScanSettingsMessage) {
        adapter.requireOn()
        permissions.require(scanPermissions())
        // Android 6 to 11 deliver no results while location is off, without
        // any error. Say so instead of scanning in silence.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && !isLocationEnabled()) {
            throw VitalBluetoothError(
                "locationServicesOff",
                "Location services are off; Android needs them on to scan.",
            )
        }
        guardSecurity { scanner.start(settings) }
    }

    private fun isLocationEnabled(): Boolean {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager?
            ?: return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    override fun stopScan() = scanner.stop()

    override suspend fun getSystemDevices(serviceUuids: List<String>): List<SystemDeviceMessage> {
        // Android can't filter connected devices by service without
        // connecting to them, so serviceUuids is ignored here.
        adapter.requireOn()
        permissions.require(connectPermissions())
        val manager = adapter.bluetoothManager ?: return emptyList()
        return guardSecurity {
            manager.getConnectedDevices(BluetoothProfile.GATT).map {
                SystemDeviceMessage(deviceId = it.address, name = runCatching { it.name }.getOrNull())
            }
        }
    }

    // --- Connection ---

    override suspend fun connect(deviceId: String, autoConnect: Boolean) {
        adapter.requireOn()
        permissions.require(connectPermissions())
        events.claim(deviceId)
        wanted.getOrPut(deviceId) { LinkedHashMap() }
        val session = sessions[deviceId] ?: newSession(deviceId)
        session.connect(autoConnect)
    }

    override suspend fun disconnect(deviceId: String) {
        wanted.remove(deviceId)
        reconnects.remove(deviceId)?.cancel()
        sessions[deviceId]?.disconnect()
    }

    override suspend fun discoverServices(deviceId: String): List<ServiceMessage> =
        session(deviceId).discoverServices()

    // --- GATT ---

    override suspend fun readCharacteristic(characteristic: CharacteristicAddressMessage): ByteArray =
        session(characteristic.deviceId).read(characteristic)

    override suspend fun writeCharacteristic(
        characteristic: CharacteristicAddressMessage,
        value: ByteArray,
        withResponse: Boolean,
    ) = session(characteristic.deviceId).write(characteristic, value, withResponse)

    override suspend fun setNotify(characteristic: CharacteristicAddressMessage, enable: Boolean) {
        session(characteristic.deviceId).setNotify(characteristic, enable)
        val subscribed = wanted[characteristic.deviceId] ?: return
        if (enable) {
            subscribed[characteristic.key] = characteristic
        } else {
            subscribed.remove(characteristic.key)
        }
    }

    override suspend fun readDescriptor(
        characteristic: CharacteristicAddressMessage,
        descriptorUuid: String,
    ): ByteArray = session(characteristic.deviceId).readDescriptor(characteristic, descriptorUuid)

    override suspend fun writeDescriptor(
        characteristic: CharacteristicAddressMessage,
        descriptorUuid: String,
        value: ByteArray,
    ) = session(characteristic.deviceId).writeDescriptor(characteristic, descriptorUuid, value)

    override suspend fun requestMtu(deviceId: String, mtu: Long): Long =
        session(deviceId).requestMtu(mtu.toInt()).toLong()

    override fun getMaximumWriteLength(deviceId: String, withResponse: Boolean): Long =
        session(deviceId).maximumWriteLength(withResponse).toLong()

    override suspend fun requestConnectionPriority(
        deviceId: String,
        priority: ConnectionPriorityMessage,
    ) = session(deviceId).requestConnectionPriority(priority)

    override suspend fun setPreferredPhy(deviceId: String, tx: PhyMessage, rx: PhyMessage) =
        session(deviceId).setPreferredPhy(tx, rx)

    override suspend fun readRssi(deviceId: String): Long = session(deviceId).readRssi().toLong()

    // --- Bonding ---

    override fun getBondState(deviceId: String): BondStateMessage {
        permissions.require(connectPermissions())
        return guardSecurity { mapBondState(remoteDevice(deviceId).bondState) }
    }

    override suspend fun createBond(deviceId: String) {
        adapter.requireOn()
        permissions.require(connectPermissions())
        val device = remoteDevice(deviceId)
        if (device.bondState == BluetoothDevice.BOND_BONDED) return
        pendingBonds[deviceId]?.let { return it.await() }
        val wait = CompletableDeferred<Unit>()
        pendingBonds[deviceId] = wait
        // Already bonding (for example the system started it): just wait.
        if (device.bondState != BluetoothDevice.BOND_BONDING) {
            val started = guardSecurity { device.createBond() }
            if (!started) {
                pendingBonds.remove(deviceId)
                throw refused("pairing")
            }
        }
        wait.await()
    }

    override suspend fun removeBond(deviceId: String) {
        permissions.require(connectPermissions())
        val device = remoteDevice(deviceId)
        if (device.bondState == BluetoothDevice.BOND_NONE) return
        // There is no public API for this. The hidden method has worked
        // on every Android version so far.
        val removed = runCatching {
            device.javaClass.getMethod("removeBond").invoke(device) as Boolean
        }.getOrDefault(false)
        if (!removed) {
            throw VitalBluetoothError("unsupported", "This phone doesn't let apps remove a bond.")
        }
    }

    // --- Helpers ---

    private fun onAdapterStateChanged(state: AdapterStateMessage) {
        events.adapterState(state)
        if (state == AdapterStateMessage.TURNING_OFF || state == AdapterStateMessage.POWERED_OFF) {
            scanner.onAdapterOff()
        }
    }

    private fun onSessionClosed(session: GattSession, dropped: Boolean) {
        if (sessions[session.deviceId] === session) sessions.remove(session.deviceId)
        // With an engine attached, Dart sees the drop and reconnects itself.
        if (dropped && backgroundMode && !events.attached && session.deviceId in wanted) {
            reconnectNatively(session.deviceId)
        }
    }

    private fun session(deviceId: String): GattSession =
        sessions[deviceId] ?: throw notConnected(deviceId)

    private fun remoteDevice(deviceId: String): BluetoothDevice {
        val bluetooth = adapter.bluetooth
            ?: throw VitalBluetoothError("unsupported", "This phone has no Bluetooth.")
        if (!BluetoothAdapter.checkBluetoothAddress(deviceId)) {
            throw VitalBluetoothError("deviceNotFound", "$deviceId is not a Bluetooth address.")
        }
        return bluetooth.getRemoteDevice(deviceId)
    }

    private fun scanPermissions() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        listOf(Manifest.permission.BLUETOOTH_SCAN)
    } else {
        listOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun connectPermissions() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        listOf(Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        emptyList()
    }

    private inline fun <T> guardSecurity(block: () -> T): T = try {
        block()
    } catch (e: SecurityException) {
        throw permissionError(e)
    }

    companion object {
        // BluetoothDevice.EXTRA_REASON is hidden, but every Android version sends it.
        private const val EXTRA_REASON = "android.bluetooth.device.extra.REASON"
        private const val RECONNECT_MIN_DELAY_MS = 1_000L
        private const val RECONNECT_MAX_DELAY_MS = 30_000L

        @Volatile
        private var instance: BleHost? = null

        /** The process-wide host, created on first use. */
        fun get(context: Context): BleHost = instance ?: synchronized(this) {
            instance ?: BleHost(context.applicationContext).also { instance = it }
        }

        /** The host if it exists, without creating it. */
        fun current(): BleHost? = instance
    }
}

internal fun mapBondState(state: Int) = when (state) {
    BluetoothDevice.BOND_BONDED -> BondStateMessage.BONDED
    BluetoothDevice.BOND_BONDING -> BondStateMessage.BONDING
    else -> BondStateMessage.NONE
}

@Suppress("DEPRECATION")
internal fun Intent.bluetoothDevice(): BluetoothDevice? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    }

private val CharacteristicAddressMessage.key: String
    get() = "$serviceUuid/$serviceInstance/$characteristicUuid/$characteristicInstance"
