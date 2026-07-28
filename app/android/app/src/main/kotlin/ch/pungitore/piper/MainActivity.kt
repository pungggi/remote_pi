package ch.pungitore.piper

import android.Manifest
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
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
                    "consumePdf" -> result.success(consumeSharePdf())
                    "consumeText" -> result.success(consumeShareText())
                    else -> result.notImplemented()
                }
            }

        // Plan 116 — connection reliability: one-tap self battery-optimization
        // exemption + deep-links to the Tailscale app-info (battery) and system
        // VPN (always-on) screens. No-op-safe: every call degrades gracefully
        // (returns false / does nothing) on older Android or when Tailscale is
        // not installed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.pungitore.piper/reliability")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBatteryOptimized" -> result.success(isBatteryOptimized())
                    "requestBatteryExemption" -> {
                        requestBatteryExemption()
                        result.success(null)
                    }
                    "openTailscaleBatterySettings" ->
                        result.success(openTailscaleBatterySettings())
                    "openVpnSettings" -> {
                        openVpnSettings()
                        result.success(null)
                    }
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

    // Plan 116 — battery-optimization + Tailscale reliability helpers.

    // true = the app is currently subject to doze/app-standby (i.e. NOT on
    // the whitelist). Below API 23 doze doesn't exist, so it's never optimized.
    private fun isBatteryOptimized(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val pm = getSystemService(POWER_SERVICE) as? PowerManager ?: return false
        return !pm.isIgnoringBatteryOptimizations(packageName)
    }

    // Shows the system "Allow Piper to always run in background?" dialog.
    // The user must confirm — we cannot silently exempt ourselves.
    private fun requestBatteryExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:$packageName"))
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "battery exemption request failed: ${e.message}")
        }
    }

    // Deep-links to Tailscale's app-info screen (user then taps Battery →
    // Unrestricted). Returns false if Tailscale isn't installed so Dart can
    // hide the row. NOTE: Piper cannot flip Tailscale's setting itself.
    private fun openTailscaleBatterySettings(): Boolean {
        val pkg = "com.tailscale.ipn"
        if (!isPackageInstalled(pkg)) return false
        return try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:$pkg"))
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "open tailscale settings failed: ${e.message}")
            false
        }
    }

    // Deep-links to the system VPN list (user enables Always-on for Tailscale).
    private fun openVpnSettings() {
        try {
            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
        } catch (e: Exception) {
            Log.w(TAG, "open vpn settings failed: ${e.message}")
        }
    }

    private fun isPackageInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (e: Exception) {
        // NameNotFoundException = not installed; SecurityException and
        // other failures can occur on some OEM ROMs. This channel is
        // documented as no-op-safe, so degrade to "not available" rather
        // than crash. Review #6.
        false
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
    private var pendingSharePdfUri: Uri? = null
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
            type == "application/pdf" -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                }
                if (uri != null) {
                    pendingSharePdfUri = uri
                    Log.d(TAG, "stashed shared pdf uri=$uri")
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
        return readImageBytes(uri, mime)
    }

    private fun readImageBytes(uri: Uri, mime: String): Map<String, Any>? = try {
        contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?.let { mapOf("data" to it, "mime" to mime) }
    } catch (e: Exception) {
        Log.w(TAG, "share read failed: ${e.javaClass.simpleName}: ${e.message}")
        null
    }

    // Plan/105 — render up to [maxPages] pages of a shared PDF to PNGs via
    // the platform PdfRenderer (no Dart PDF dependency). Each page is scaled
    // to ~1242px wide on a white background (PDFs can be transparent).
    private fun renderPdfPages(uri: Uri, maxPages: Int): List<Map<String, Any>> {
        var pfd: android.os.ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        val out = mutableListOf<Map<String, Any>>()
        try {
            pfd = contentResolver.openFileDescriptor(uri, "r") ?: return emptyList()
            renderer = PdfRenderer(pfd)
            val count = minOf(renderer.pageCount, maxPages)
            for (i in 0 until count) {
                var page: PdfRenderer.Page? = null
                try {
                    page = renderer.openPage(i)
                    val targetWidth = 1242
                    val scale = targetWidth.toFloat() / page.width.toFloat()
                    val width = targetWidth
                    val height = (page.height * scale).toInt()
                    val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    bmp.eraseColor(android.graphics.Color.WHITE)
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val bytes = java.io.ByteArrayOutputStream().use { baos ->
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, baos)
                        baos.toByteArray()
                    }
                    bmp.recycle()
                    out.add(mapOf("data" to bytes, "mime" to "image/png"))
                } finally {
                    page?.close()
                }
            }
            Log.d(TAG, "rendered pdf $count of ${renderer.pageCount} pages")
        } catch (e: Exception) {
            Log.w(TAG, "pdf render failed: ${e.javaClass.simpleName}: ${e.message}")
        } finally {
            renderer?.close()
            pfd?.close()
        }
        return out
    }

    // Plan/105 — consume the stashed shared PDF: render up to 8 pages.
    private fun consumeSharePdf(): List<Map<String, Any>> {
        val uri = pendingSharePdfUri ?: return emptyList()
        pendingSharePdfUri = null
        return renderPdfPages(uri, 8)
    }

    // Plan/104 — text/plain share (EXTRA_TEXT). Cleared on read.
    private fun consumeShareText(): String? {
        val t = pendingShareText
        pendingShareText = null
        return t
    }
}
