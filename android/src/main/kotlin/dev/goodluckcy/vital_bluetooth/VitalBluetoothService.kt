package dev.goodluckcy.vital_bluetooth

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * The foreground service behind background mode.
 *
 * It does no Bluetooth work itself. While it runs, Android treats the
 * process as in use, so it isn't killed in the background and BLE callbacks
 * keep arriving with the screen off. [BleHost] keeps the links.
 *
 * The notification uses the drawable named `vital_bluetooth_notification`
 * when the app has one, and the app icon otherwise. Tapping it opens the
 * app.
 */
class VitalBluetoothService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        try {
            val notification = buildNotification(title, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // For example a missing permission, or Android refusing a start
            // from the background.
            Log.e(TAG, "Can't start the background-mode service", e)
            BleHost.current()?.onServiceFailed()
            stopSelf()
        }
        // If Android kills the process anyway, the links are gone with it,
        // so restarting the service alone would help nobody.
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(title: String, text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Bluetooth connection",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(notificationIcon())
            .setOngoing(true)
            .setContentIntent(launch)
            .build()
    }

    private fun notificationIcon(): Int {
        @Suppress("DiscouragedApi") // The app names it; there is no R entry here.
        val custom = resources.getIdentifier("vital_bluetooth_notification", "drawable", packageName)
        return if (custom != 0) custom else applicationInfo.icon
    }

    internal companion object {
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "vital_bluetooth"
        private const val NOTIFICATION_ID = 0xB1E

        /** Throws IllegalStateException when Android refuses the start. */
        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, VitalBluetoothService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VitalBluetoothService::class.java))
        }
    }
}
