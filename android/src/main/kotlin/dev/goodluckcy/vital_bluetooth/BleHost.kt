package dev.goodluckcy.vital_bluetooth

/**
 * Android side of [BleHostApi].
 *
 * Only the API shape is in place so far. Every call that isn't implemented
 * yet throws an `unsupported` error, so Dart gets a clear message instead of
 * a missing-channel error.
 */
internal class BleHost(
    @Suppress("unused") private val events: BleFlutterApi,
) : BleHostApi {
    override fun getCapabilities() = CapabilitiesMessage(
        ble = true,
        classic = true,
        bonding = true,
        connectionPriority = true,
        phy = true,
    )

    override fun getAdapterState(): AdapterStateMessage = notImplemented()

    override suspend fun turnOn(): Unit = notImplemented()

    override fun getPermissionStatus(): PermissionStatusMessage = notImplemented()

    override suspend fun requestPermissions(): PermissionStatusMessage = notImplemented()

    override suspend fun startScan(settings: ScanSettingsMessage): Unit = notImplemented()

    override fun stopScan(): Unit = notImplemented()

    override suspend fun getSystemDevices(serviceUuids: List<String>): List<SystemDeviceMessage> =
        notImplemented()

    override suspend fun connect(deviceId: String, autoConnect: Boolean): Unit = notImplemented()

    override suspend fun disconnect(deviceId: String): Unit = notImplemented()

    override suspend fun discoverServices(deviceId: String): List<ServiceMessage> =
        notImplemented()

    override suspend fun readCharacteristic(characteristic: CharacteristicAddressMessage): ByteArray =
        notImplemented()

    override suspend fun writeCharacteristic(
        characteristic: CharacteristicAddressMessage,
        value: ByteArray,
        withResponse: Boolean,
    ): Unit = notImplemented()

    override suspend fun setNotify(characteristic: CharacteristicAddressMessage, enable: Boolean): Unit =
        notImplemented()

    override suspend fun readDescriptor(
        characteristic: CharacteristicAddressMessage,
        descriptorUuid: String,
    ): ByteArray = notImplemented()

    override suspend fun writeDescriptor(
        characteristic: CharacteristicAddressMessage,
        descriptorUuid: String,
        value: ByteArray,
    ): Unit = notImplemented()

    override suspend fun requestMtu(deviceId: String, mtu: Long): Long = notImplemented()

    override fun getMaximumWriteLength(deviceId: String, withResponse: Boolean): Long =
        notImplemented()

    override suspend fun requestConnectionPriority(
        deviceId: String,
        priority: ConnectionPriorityMessage,
    ): Unit = notImplemented()

    override suspend fun setPreferredPhy(deviceId: String, tx: PhyMessage, rx: PhyMessage): Unit =
        notImplemented()

    override suspend fun readRssi(deviceId: String): Long = notImplemented()

    override fun getBondState(deviceId: String): BondStateMessage = notImplemented()

    override suspend fun createBond(deviceId: String): Unit = notImplemented()

    override suspend fun removeBond(deviceId: String): Unit = notImplemented()
}

internal fun notImplemented(): Nothing =
    throw VitalBluetoothError("unsupported", "Not implemented on Android yet.")
