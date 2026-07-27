package ch.pungitore.piper

import android.Manifest
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "ch.pungitore.piper/keepalive"
        const val NOTIF_PERM_REQUEST = 10302
        const val TAG = "PiperClip"
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

        // Plan/104 — consume a shared image (Android Share sheet → ACTION_SEND).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.pungitore.piper/share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeImage" -> result.success(consumeShareImage())
                    "consumeText" -> result.success(consumeShareText())
                    else -> result.notImplemented()
                }
            }

        // Cold start: the launch intent may itself be a share.
        stashShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        stashShareIntent(intent)
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
    // clipboard holds no image. Logged (tag PiperClip) to diagnose quirks.
    private fun readClipboardImage(): Map<String, Any>? {
        val cm = getSystemService(ClipboardManager::class.java)
        if (cm == null) { Log.w(TAG, "no ClipboardManager"); return null }
        val clip = cm.primaryClip
        if (clip == null) { Log.w(TAG, "primaryClip null (empty)"); return null }
        val desc = clip.description
        val mimes = (0 until desc.mimeTypeCount).joinToString(",") { desc.getMimeType(it) }
        Log.d(TAG, "clip itemCount=${clip.itemCount} mimes=[$mimes]")
        val advertisesImage = mimes.split(',').any { it.startsWith("image/") }
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val uri = item.uri
            Log.d(TAG, "item[$i] uri=$uri text=${item.text?.toString()?.take(40)} intent=${item.intent != null}")
            if (uri == null) continue
            val mime = contentResolver.getType(uri) ?: if (advertisesImage) "image/png" else null
            if (mime == null) { Log.w(TAG, "item[$i] getType null"); continue }
            if (!mime.startsWith("image/")) { Log.w(TAG, "item[$i] not image: $mime"); continue }
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes != null) {
                    Log.d(TAG, "item[$i] read ${bytes.size} bytes ($mime)")
                    return mapOf("data" to bytes, "mime" to mime)
                }
            } catch (e: Exception) {
                Log.w(TAG, "item[$i] read failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        Log.w(TAG, "no readable image found")
        return null
    }

    // Plan/104 — a shared image URI stashed from onCreate/onNewIntent until
    // Dart consumes it. ACTION_SEND grants the receiving activity a temporary
    // read grant, so openInputStream works without extra permissions.
    private var pendingShareUri: Uri? = null
    private var pendingShareText: String? = null

    private fun stashShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val type = intent.type ?: return
        when {
            type.startsWith("image/") -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                }
                if (uri != null) {
                    pendingShareUri = uri
                    Log.d(TAG, "stashed shared image uri=$uri")
                }
            }
            type.startsWith("text/") -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (!text.isNullOrEmpty()) {
                    pendingShareText = text
                    Log.d(TAG, "stashed shared text (${text.length} chars)")
                }
            }
        }
    }

    private fun consumeShareImage(): Map<String, Any>? {
        val uri = pendingShareUri ?: return null
        pendingShareUri = null
        val mime = contentResolver.getType(uri) ?: "image/*"
        if (!mime.startsWith("image/")) return null
        return try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?.let { mapOf("data" to it, "mime" to mime) }
        } catch (e: Exception) {
            Log.w(TAG, "share read failed: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    // Plan/104 — text/plain share (EXTRA_TEXT). Cleared on read.
    private fun consumeShareText(): String? {
        val t = pendingShareText
        pendingShareText = null
        return t
    }
}
