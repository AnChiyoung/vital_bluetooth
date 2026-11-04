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
import android.os.Build
import kotlinx.coroutines.CompletableDeferred

/**
 * Android side of [BleHostApi].
 *
 * Every call runs on the main thread (Pigeon starts the coroutines there).
 * Each connected device has its own [GattSession].
 */
@SuppressLint("MissingPermission") // Every entry point checks permissions first.
internal class BleHost(
    private val context: Context,
    api: BleFlutterApi,
) : BleHostApi {
    private val events = BleEventSender(api)
    private val permissions = Permissions(context)
    private val adapter = Adapter(context, ::onAdapterStateChanged)
    private val scanner = Scanner(adapter, events)
    private val sessions = HashMap<String, GattSession>()
    private val pendingBonds = HashMap<String, CompletableDeferred<Unit>>()

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

    fun start() {
        adapter.start()
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(bondReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(bondReceiver, filter)
        }
    }

    fun attachActivity(activity: Activity?) {
        permissions.attach(activity)
        adapter.attach(activity)
    }

    val permissionListener get() = permissions
    val activityResultListener get() = adapter

    fun dispose() {
        scanner.stop()
        sessions.values.toList().forEach { it.release() }
        sessions.clear()
        pendingBonds.values.forEach {
            it.completeExceptionally(VitalBluetoothError("unknown", "The plugin was detached."))
        }
        pendingBonds.clear()
        context.unregisterReceiver(bondReceiver)
        adapter.stop()
        events.dispose()
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
        guardSecurity { scanner.start(settings) }
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
        val session = sessions.getOrPut(deviceId) {
            GattSession(deviceId, context, remoteDevice(deviceId), events, ::onSessionClosed)
        }
        session.connect(autoConnect)
    }

    override suspend fun disconnect(deviceId: String) {
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

    override suspend fun setNotify(characteristic: CharacteristicAddressMessage, enable: Boolean) =
        session(characteristic.deviceId).setNotify(characteristic, enable)

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

    private fun onSessionClosed(session: GattSession) {
        if (sessions[session.deviceId] === session) sessions.remove(session.deviceId)
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

    private companion object {
        // BluetoothDevice.EXTRA_REASON is hidden, but every Android version sends it.
        const val EXTRA_REASON = "android.bluetooth.device.extra.REASON"
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
