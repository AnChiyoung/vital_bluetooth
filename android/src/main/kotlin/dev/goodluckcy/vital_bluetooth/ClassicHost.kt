package dev.goodluckcy.vital_bluetooth

/**
 * Android side of [ClassicHostApi] (RFCOMM / SPP).
 *
 * Only the API shape is in place so far.
 */
internal class ClassicHost(
    @Suppress("unused") private val events: ClassicFlutterApi,
) : ClassicHostApi {
    override suspend fun getBondedDevices(): List<ClassicDeviceMessage> = notImplemented()

    override suspend fun startDiscovery(): Unit = notImplemented()

    override suspend fun stopDiscovery(): Unit = notImplemented()

    override suspend fun connect(deviceId: String, serviceUuid: String, secure: Boolean): Unit =
        notImplemented()

    override suspend fun disconnect(deviceId: String): Unit = notImplemented()

    override suspend fun write(deviceId: String, data: ByteArray): Unit = notImplemented()
}
