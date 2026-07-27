package ch.pungitore.piper

import android.Manifest
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "ch.pungitore.piper/keepalive"
        const val NOTIF_PERM_REQUEST = 10302
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val text = call.argument<String>("text") ?: "Connected"
                        val intent = Intent(this, KeepAliveService::class.java).apply {
                            action = KeepAliveService.ACTION_START
                            putExtra(KeepAliveService.EXTRA_TEXT, text)
                        }
                        try {
                            ContextCompat.startForegroundService(this, intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // Android 12+ throws ForegroundServiceStartNotAllowedException
                            // when the app isn't in a foreground-allowed state. Report
                            // failure so Dart doesn't mark the service as started; it
                            // retries on the next (foreground) status change.
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        // stopService is always allowed (no background-start
                        // restriction like startForegroundService has).
                        stopService(Intent(this, KeepAliveService::class.java))
                        result.success(true)
                    }
                    "hasNotificationPermission" -> result.success(hasNotificationPermission())
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(hasNotificationPermission())
                    }
                    else -> result.notImplemented()
                }
            }

        // Plan/30-followup — clipboard image read for paste-to-attach.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.pungitore.piper/clipboard")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readImage" -> result.success(readClipboardImage())
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (hasNotificationPermission()) return
        // No-op if the Activity isn't resumed (e.g. invoked while backgrounded);
        // the service still starts, the notification is just hidden until the
        // user grants permission from Settings.
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIF_PERM_REQUEST,
        )
    }

    // Plan/30-followup — read the image on the system clipboard (e.g. a
    // screenshot). Returns { data: ByteArray, mime } or null when the
    // clipboard holds no image (text-only / empty / unreadable).
    private fun readClipboardImage(): Map<String, Any>? {
        val cm = getSystemService(ClipboardManager::class.java) ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val uri = clip.getItemAt(0).uri ?: return null
        val mime = contentResolver.getType(uri) ?: return null
        if (!mime.startsWith("image/")) return null
        return try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?.let { mapOf("data" to it, "mime" to mime) }
        } catch (e: Exception) {
            null
        }
    }
}
