package dev.goodluckcy.vital_bluetooth

// Errors use the codes listed at the top of pigeons/messages.dart.

internal fun notConnected(deviceId: String) =
    VitalBluetoothError("notConnected", "$deviceId is not connected.")

internal fun connectionFailed(deviceId: String, status: Int) = VitalBluetoothError(
    "connectionFailed",
    "Connecting to $deviceId failed with status $status.",
    status.toString(),
)

internal fun gattError(status: Int) = VitalBluetoothError(
    "gattError",
    "The device answered with GATT status $status.",
    status,
)

internal fun attributeNotFound(uuid: String) =
    VitalBluetoothError("attributeNotFound", "$uuid was not found on the device.", uuid)

internal fun refused(what: String) = VitalBluetoothError(
    "unknown",
    "Android refused to start $what. The link may have dropped or the " +
        "characteristic may not support it.",
)

internal fun permissionError(e: SecurityException) =
    VitalBluetoothError("permissionDenied", e.message ?: "Missing Bluetooth permission.")

internal fun notImplemented(): Nothing =
    throw VitalBluetoothError("unsupported", "Not implemented on Android yet.")
