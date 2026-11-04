package dev.goodluckcy.vital_bluetooth

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred

/**
 * Checks and requests the runtime permissions BLE needs.
 *
 * Android 12+ needs BLUETOOTH_SCAN and BLUETOOTH_CONNECT. Android 6 to 11
 * needs location to scan.
 */
internal class Permissions(private val context: Context) :
    PluginRegistry.RequestPermissionsResultListener {

    private var activity: Activity? = null
    private var pending: CompletableDeferred<PermissionStatusMessage>? = null
    private var notificationsPending: CompletableDeferred<Unit>? = null
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    val required: List<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    fun attach(activity: Activity?) {
        this.activity = activity
        if (activity == null) {
            pending?.complete(status())
            pending = null
            notificationsPending?.complete(Unit)
            notificationsPending = null
        }
    }

    fun missing(): List<String> = required.filter {
        context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
    }

    fun has(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Throws `permissionDenied` unless every permission in [permissions] is granted. */
    fun require(permissions: List<String> = required) {
        val missing = permissions.filterNot(::has)
        if (missing.isNotEmpty()) {
            throw VitalBluetoothError(
                "permissionDenied",
                "Missing Bluetooth permissions: $missing",
                missing,
            )
        }
    }

    fun status(): PermissionStatusMessage {
        val missing = missing()
        if (missing.isEmpty()) return PermissionStatusMessage.GRANTED
        val activity = activity ?: return PermissionStatusMessage.DENIED
        // Android only says "permanently denied" indirectly: after the app
        // has asked once, the rationale flag stays false when the user picked
        // "don't ask again".
        val askedBefore = missing.all { prefs.getBoolean(it, false) }
        val noRationale = missing.none { activity.shouldShowRequestPermissionRationale(it) }
        return if (askedBefore && noRationale) {
            PermissionStatusMessage.PERMANENTLY_DENIED
        } else {
            PermissionStatusMessage.DENIED
        }
    }

    suspend fun request(): PermissionStatusMessage {
        val missing = missing()
        if (missing.isEmpty()) return PermissionStatusMessage.GRANTED
        val activity = activity ?: throw VitalBluetoothError(
            "unknown",
            "Permissions can only be requested while an Activity is attached.",
        )
        pending?.let { return it.await() }
        val deferred = CompletableDeferred<PermissionStatusMessage>()
        pending = deferred
        prefs.edit().apply { missing.forEach { putBoolean(it, true) } }.apply()
        activity.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
        return deferred.await()
    }

    /**
     * Asks for POST_NOTIFICATIONS on Android 13+, so the background-mode
     * notification shows. Background mode works without it; the notification
     * is just hidden. Returns at once when there is no Activity.
     */
    suspend fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (has(permission)) return
        val activity = activity ?: return
        notificationsPending?.let { return it.await() }
        val deferred = CompletableDeferred<Unit>()
        notificationsPending = deferred
        activity.requestPermissions(arrayOf(permission), NOTIFICATIONS_REQUEST_CODE)
        deferred.await()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode == NOTIFICATIONS_REQUEST_CODE) {
            notificationsPending?.complete(Unit)
            notificationsPending = null
            return true
        }
        if (requestCode != REQUEST_CODE) return false
        pending?.complete(status())
        pending = null
        return true
    }

    private companion object {
        const val REQUEST_CODE = 0xB1E
        const val NOTIFICATIONS_REQUEST_CODE = 0xB1F
        const val PREFS = "dev.goodluckcy.vital_bluetooth.permissions"
    }
}
