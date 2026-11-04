package dev.goodluckcy.vital_bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One device's GATT link.
 *
 * Android allows one GATT operation at a time per link. The Dart side
 * already sends them one by one through its OperationQueue, so this class
 * keeps a single pending slot. A new call while one is pending means Dart
 * gave up on the old one (timeout), so the old one is failed and replaced.
 *
 * On every disconnect or failed connect the BluetoothGatt is closed. Leaving
 * it open is the main cause of Android's repeated status 133.
 */
@SuppressLint("MissingPermission") // BleHost checks permissions first.
internal class GattSession(
    val deviceId: String,
    private val context: Context,
    private val device: BluetoothDevice,
    private val events: BleEventSender,
    private val onClosed: (GattSession) -> Unit,
) {
    private enum class Kind {
        DISCOVER, READ, WRITE, READ_DESCRIPTOR, WRITE_DESCRIPTOR, MTU, PHY, RSSI
    }

    private class Pending(val kind: Kind, val result: CompletableDeferred<Any?>)

    private val lock = Any()
    private var gatt: BluetoothGatt? = null
    private var connected = false
    private var connectWait: CompletableDeferred<Unit>? = null
    private var disconnectWait: CompletableDeferred<Unit>? = null
    private var pending: Pending? = null

    var mtu = DEFAULT_MTU
        private set

    suspend fun connect(autoConnect: Boolean) {
        val wait = CompletableDeferred<Unit>()
        val running = synchronized(lock) {
            if (connected) return
            connectWait.also { if (it == null) connectWait = wait }
        }
        if (running != null) return running.await()
        events.connectionState(deviceId, ConnectionStateMessage.CONNECTING)
        val gatt = try {
            device.connectGatt(context, autoConnect, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            synchronized(lock) { connectWait = null }
            throw permissionError(e)
        }
        if (gatt == null) {
            synchronized(lock) { connectWait = null }
            events.connectionState(deviceId, ConnectionStateMessage.DISCONNECTED)
            onClosed(this)
            throw connectionFailed(deviceId, -1)
        }
        synchronized(lock) {
            // The callback may already have adopted it, or closed the
            // attempt; in that case wait already holds the answer.
            if (connectWait === wait && this.gatt == null) this.gatt = gatt
        }
        try {
            wait.await()
        } finally {
            synchronized(lock) { if (connectWait === wait) connectWait = null }
        }
    }

    /** Closes the link. Safe in any state, including while connecting. */
    suspend fun disconnect() {
        val (gatt, wasConnected) = synchronized(lock) { gatt to connected }
        if (gatt == null) {
            onClosed(this)
            return
        }
        events.connectionState(deviceId, ConnectionStateMessage.DISCONNECTING)
        if (wasConnected) {
            val wait = CompletableDeferred<Unit>()
            synchronized(lock) { disconnectWait = wait }
            runCatching { gatt.disconnect() }
            // Some phones never report the disconnect. Close anyway.
            withTimeoutOrNull(DISCONNECT_TIMEOUT_MS) { wait.await() }
        }
        close(error = null, connectError = notConnected(deviceId))
    }

    /** Closes the link at once without waiting, for when the engine goes away. */
    fun release() = close(error = null, connectError = notConnected(deviceId))

    suspend fun discoverServices(): List<ServiceMessage> {
        perform<Unit>(Kind.DISCOVER, "service discovery") { it.discoverServices() }
        return requireGatt().services.map { it.toMessage() }
    }

    suspend fun read(address: CharacteristicAddressMessage): ByteArray {
        val characteristic = find(address)
        return perform(Kind.READ, "read") { it.readCharacteristic(characteristic) }
    }

    @Suppress("DEPRECATION")
    suspend fun write(address: CharacteristicAddressMessage, value: ByteArray, withResponse: Boolean) {
        val characteristic = find(address)
        val type = if (withResponse) {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }
        // Android reports writes without response too, once the value is
        // queued. Waiting for that keeps fast writers from overflowing the
        // stack's buffer.
        perform<Unit>(Kind.WRITE, "write") { gatt ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, value, type) == BluetoothStatusCodes.SUCCESS
            } else {
                characteristic.writeType = type
                characteristic.value = value
                gatt.writeCharacteristic(characteristic)
            }
        }
    }

    suspend fun setNotify(address: CharacteristicAddressMessage, enable: Boolean) {
        val characteristic = find(address)
        val gatt = requireGatt()
        if (!gatt.setCharacteristicNotification(characteristic, enable)) {
            throw refused("notifications")
        }
        // A few devices send notifications without a CCCD to write.
        val cccd = characteristic.getDescriptor(CCCD) ?: return
        val properties = characteristic.properties
        val value = when {
            !enable -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 ->
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0 ->
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            else -> throw VitalBluetoothError(
                "unsupported",
                "${address.characteristicUuid} supports neither notify nor indicate.",
            )
        }
        writeDescriptor(cccd, value)
    }

    suspend fun readDescriptor(address: CharacteristicAddressMessage, uuid: String): ByteArray {
        val descriptor = findDescriptor(address, uuid)
        return perform(Kind.READ_DESCRIPTOR, "descriptor read") { it.readDescriptor(descriptor) }
    }

    suspend fun writeDescriptor(address: CharacteristicAddressMessage, uuid: String, value: ByteArray) =
        writeDescriptor(findDescriptor(address, uuid), value)

    suspend fun requestMtu(mtu: Int): Int =
        perform(Kind.MTU, "MTU request") { it.requestMtu(mtu) }

    fun maximumWriteLength(withResponse: Boolean): Int {
        val payload = mtu - ATT_HEADER
        // A long write (with response) can't exceed 512 bytes per attribute.
        return if (withResponse) minOf(payload, MAX_ATTRIBUTE_LENGTH) else payload
    }

    fun requestConnectionPriority(priority: ConnectionPriorityMessage) {
        val value = when (priority) {
            ConnectionPriorityMessage.BALANCED -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
            ConnectionPriorityMessage.HIGH -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
            ConnectionPriorityMessage.LOW_POWER -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
        }
        if (!requireGatt().requestConnectionPriority(value)) throw refused("connection priority")
    }

    suspend fun setPreferredPhy(tx: PhyMessage, rx: PhyMessage) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            throw VitalBluetoothError("unsupported", "Choosing the PHY needs Android 8.")
        }
        perform<Unit>(Kind.PHY, "PHY update") {
            it.setPreferredPhy(tx.mask, rx.mask, BluetoothDevice.PHY_OPTION_NO_PREFERRED)
            true
        }
    }

    suspend fun readRssi(): Int = perform(Kind.RSSI, "RSSI read") { it.readRemoteRssi() }

    @Suppress("DEPRECATION")
    private suspend fun writeDescriptor(descriptor: BluetoothGattDescriptor, value: ByteArray) {
        perform<Unit>(Kind.WRITE_DESCRIPTOR, "descriptor write") { gatt ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
            } else {
                descriptor.value = value
                gatt.writeDescriptor(descriptor)
            }
        }
    }

    /** Starts one GATT operation and waits for its callback. */
    private suspend fun <T> perform(kind: Kind, what: String, start: (BluetoothGatt) -> Boolean): T {
        val gatt = requireGatt()
        val result = CompletableDeferred<Any?>()
        val stale = synchronized(lock) {
            pending.also { pending = Pending(kind, result) }
        }
        stale?.result?.completeExceptionally(
            VitalBluetoothError("unknown", "Replaced by a newer operation."),
        )
        val started = try {
            start(gatt)
        } catch (e: SecurityException) {
            clearPending(result)
            throw permissionError(e)
        }
        if (!started) {
            clearPending(result)
            throw refused(what)
        }
        @Suppress("UNCHECKED_CAST")
        return result.await() as T
    }

    private fun clearPending(result: CompletableDeferred<Any?>) = synchronized(lock) {
        if (pending?.result === result) pending = null
    }

    private fun finish(kind: Kind, status: Int, value: Any?) {
        val done = synchronized(lock) {
            pending?.takeIf { it.kind == kind }?.also { pending = null }
        } ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            done.result.complete(value)
        } else {
            done.result.completeExceptionally(gattError(status))
        }
    }

    /**
     * Closes the BluetoothGatt once and tells everyone who is waiting.
     *
     * [error] goes to Dart with the disconnected event (null for a drop the
     * app asked for). [connectError] fails a connect that was still waiting.
     */
    private fun close(error: PlatformErrorMessage?, connectError: VitalBluetoothError) {
        val closed = synchronized(lock) {
            val gatt = gatt ?: return@synchronized null
            this.gatt = null
            connected = false
            val waits = Triple(connectWait, disconnectWait, pending)
            connectWait = null
            disconnectWait = null
            pending = null
            gatt to waits
        } ?: return
        val (gatt, waits) = closed
        runCatching { gatt.close() }
        waits.first?.completeExceptionally(connectError)
        waits.second?.complete(Unit)
        waits.third?.result?.completeExceptionally(notConnected(deviceId))
        events.connectionState(deviceId, ConnectionStateMessage.DISCONNECTED, error)
        onClosed(this)
    }

    /**
     * Whether a callback for [gatt] belongs to the current link. A callback
     * can arrive before connectGatt() has returned, so a connect that is
     * still waiting takes the object over. Call with [lock] held.
     */
    private fun adopt(gatt: BluetoothGatt): Boolean {
        val current = this.gatt
        if (current == null && connectWait != null) {
            this.gatt = gatt
            return true
        }
        return current === gatt
    }

    private fun requireGatt(): BluetoothGatt = synchronized(lock) {
        gatt.takeIf { connected }
    } ?: throw notConnected(deviceId)

    private fun find(address: CharacteristicAddressMessage): BluetoothGattCharacteristic {
        val serviceUuid = UUID.fromString(address.serviceUuid)
        val service = requireGatt().services.firstOrNull {
            it.uuid == serviceUuid && it.instanceId.toLong() == address.serviceInstance
        } ?: throw attributeNotFound(address.serviceUuid)
        val characteristicUuid = UUID.fromString(address.characteristicUuid)
        return service.characteristics.firstOrNull {
            it.uuid == characteristicUuid && it.instanceId.toLong() == address.characteristicInstance
        } ?: throw attributeNotFound(address.characteristicUuid)
    }

    private fun findDescriptor(address: CharacteristicAddressMessage, uuid: String) =
        find(address).getDescriptor(UUID.fromString(uuid)) ?: throw attributeNotFound(uuid)

    private fun BluetoothGattCharacteristic.address() = CharacteristicAddressMessage(
        deviceId = deviceId,
        serviceUuid = service.uuid.toString(),
        serviceInstance = service.instanceId.toLong(),
        characteristicUuid = uuid.toString(),
        characteristicInstance = instanceId.toLong(),
    )

    private fun notify(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        events.value(
            CharacteristicValueMessage(
                characteristic = characteristic.address(),
                value = value,
                timestampMicros = System.currentTimeMillis() * 1000,
            ),
        )
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                val wait = synchronized(lock) {
                    if (!adopt(gatt)) return
                    connected = true
                    connectWait
                }
                mtu = DEFAULT_MTU
                events.connectionState(deviceId, ConnectionStateMessage.CONNECTED)
                wait?.complete(Unit)
                return
            }
            // Disconnected, or a failed connect.
            val (wasConnected, expected) = synchronized(lock) {
                if (!adopt(gatt)) {
                    runCatching { gatt.close() }
                    return
                }
                connected to (disconnectWait != null)
            }
            val error = when {
                expected -> null
                wasConnected -> PlatformErrorMessage(
                    code = "notConnected",
                    message = "The link dropped (status $status).",
                    platformCode = status.toString(),
                )
                else -> PlatformErrorMessage(
                    code = "connectionFailed",
                    message = "Connecting failed (status $status).",
                    platformCode = status.toString(),
                )
            }
            close(error, connectionFailed(deviceId, status))
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) =
            finish(Kind.DISCOVER, status, Unit)

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) = finish(Kind.READ, status, value)

        @Deprecated("Used before Android 13")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            finish(Kind.READ, status, characteristic.value ?: ByteArray(0))
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) = finish(Kind.WRITE, status, Unit)

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = notify(characteristic, value)

        @Deprecated("Used before Android 13")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            // Copy: Android reuses the array for the next value.
            notify(characteristic, characteristic.value?.copyOf() ?: ByteArray(0))
        }

        override fun onDescriptorRead(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
            value: ByteArray,
        ) = finish(Kind.READ_DESCRIPTOR, status, value)

        @Deprecated("Used before Android 13")
        @Suppress("DEPRECATION")
        override fun onDescriptorRead(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            finish(Kind.READ_DESCRIPTOR, status, descriptor.value ?: ByteArray(0))
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) = finish(Kind.WRITE_DESCRIPTOR, status, Unit)

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                this@GattSession.mtu = mtu
                events.mtuChanged(deviceId, mtu)
            }
            finish(Kind.MTU, status, mtu)
        }

        override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) =
            finish(Kind.PHY, status, Unit)

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) =
            finish(Kind.RSSI, status, rssi)

        override fun onServiceChanged(gatt: BluetoothGatt) = events.servicesChanged(deviceId)
    }

    private companion object {
        const val DEFAULT_MTU = 23
        const val ATT_HEADER = 3
        const val MAX_ATTRIBUTE_LENGTH = 512
        const val DISCONNECT_TIMEOUT_MS = 2_000L
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}

private val PhyMessage.mask: Int
    get() = when (this) {
        PhyMessage.LE1M -> BluetoothDevice.PHY_LE_1M_MASK
        PhyMessage.LE2M -> BluetoothDevice.PHY_LE_2M_MASK
        PhyMessage.LE_CODED -> BluetoothDevice.PHY_LE_CODED_MASK
    }

private fun BluetoothGattService.toMessage(): ServiceMessage = ServiceMessage(
    uuid = uuid.toString(),
    instance = instanceId.toLong(),
    isPrimary = type == BluetoothGattService.SERVICE_TYPE_PRIMARY,
    characteristics = characteristics.map { c ->
        val p = c.properties
        CharacteristicMessage(
            uuid = c.uuid.toString(),
            instance = c.instanceId.toLong(),
            properties = CharacteristicPropertiesMessage(
                broadcast = p and BluetoothGattCharacteristic.PROPERTY_BROADCAST != 0,
                read = p and BluetoothGattCharacteristic.PROPERTY_READ != 0,
                writeWithoutResponse = p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0,
                write = p and BluetoothGattCharacteristic.PROPERTY_WRITE != 0,
                notify = p and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0,
                indicate = p and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0,
                authenticatedSignedWrites =
                    p and BluetoothGattCharacteristic.PROPERTY_SIGNED_WRITE != 0,
                extendedProperties = p and BluetoothGattCharacteristic.PROPERTY_EXTENDED_PROPS != 0,
            ),
            descriptors = c.descriptors.map { DescriptorMessage(uuid = it.uuid.toString()) },
        )
    },
    includedServices = includedServices.map { it.uuid.toString() },
)
