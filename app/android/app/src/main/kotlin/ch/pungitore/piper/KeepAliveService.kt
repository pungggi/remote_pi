package ch.pungitore.piper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Plan 103 — foreground "priority anchor".
 *
 * The service itself runs no Dart. It exists solely to hold a persistent
 * notification, which elevates the whole app process to foreground priority so
 * Android does not freeze it on background. The Dart root isolate
 * (ConnectionManager + WsTransport + the 25 s keep-alive pings) then keeps
 * running and the relay WebSocket stays alive across focus changes.
 *
 * Start / stop / text updates arrive via the `ch.pungitore.piper/keepalive`
 * MethodChannel (see [MainActivity]), driven by `KeepAliveController` on the
 * Dart side.
 */
class KeepAliveService : Service() {

    companion object {
        const val ACTION_START = "ch.pungitore.piper.KEEPALIVE_START"
        const val ACTION_STOP = "ch.pungitore.piper.KEEPALIVE_STOP"
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "piper_connection"
        private const val NOTIF_ID = 10301
    }

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Connected"
                try {
                    startForeground(
                        NOTIF_ID,
                        buildNotification(text),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } catch (e: Exception) {
                    // Cannot enter foreground (e.g. the app is not in a
                    // foreground-allowed state on Android 12+, or a sticky
                    // restart after a kill). Bail out cleanly; Dart re-drives
                    // start on the next status change.
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }
        // NOT_STICKY: if the OS kills the process, the app restarts fresh on
        // next launch and KeepAliveController re-attaches + re-starts. A sticky
        // restart cannot call startForeground while the app isn't foreground.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // Drop the notification if the service is stopped any other way, so it
        // never lingers detached from a live service.
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Connection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description =
                    "Keeps Piper connected to your PC while the app is in the background."
                setShowBadge(false)
                enableVibration(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle("Piper")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .apply { if (pendingIntent != null) setContentIntent(pendingIntent) }
            .build()
    }
}
