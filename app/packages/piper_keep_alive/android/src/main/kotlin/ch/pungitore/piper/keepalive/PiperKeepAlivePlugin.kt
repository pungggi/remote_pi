package ch.pungitore.piper.keepalive

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Registers the keep-alive channel on normal AND connector background engines. */
class PiperKeepAlivePlugin : FlutterPlugin {
    private companion object {
        const val CHANNEL = "ch.pungitore.piper/keepalive"
        const val SERVICE_CLASS = "ch.pungitore.piper.KeepAliveService"
        const val ACTION_START = "ch.pungitore.piper.KEEPALIVE_START"
        const val EXTRA_TEXT = "text"
    }

    private val keepAliveClass by lazy { Class.forName(SERVICE_CLASS) }
    private val keepAliveCompanion by lazy {
        keepAliveClass.getField("Companion").get(null)
    }

    private lateinit var context: Context
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel = methodChannel
        setDartChannel(methodChannel)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val text = call.argument<String>("text") ?: "Connected"
                    val intent = Intent(context, keepAliveClass).apply {
                        action = ACTION_START
                        putExtra(EXTRA_TEXT, text)
                    }
                    try {
                        ContextCompat.startForegroundService(context, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        methodChannel.invokeMethod("onStartRefused", null)
                        result.success(false)
                    }
                }
                "stop" -> {
                    context.stopService(Intent(context, keepAliveClass))
                    result.success(true)
                }
                "hasNotificationPermission" ->
                    result.success(hasNotificationPermission())
                // A connector-only engine has no Activity that can show the
                // permission dialog. Return the current state; the foreground
                // Activity retains the real request flow.
                "requestNotificationPermission" ->
                    result.success(hasNotificationPermission())
                "isCharging" -> result.success(isCharging())
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (getDartChannel() === channel) setDartChannel(null)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun setDartChannel(value: MethodChannel?) {
        keepAliveCompanion.javaClass
            .getMethod("setDartChannel", MethodChannel::class.java)
            .invoke(keepAliveCompanion, value)
    }

    private fun getDartChannel(): MethodChannel? =
        keepAliveCompanion.javaClass
            .getMethod("getDartChannel")
            .invoke(keepAliveCompanion) as? MethodChannel

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun isCharging(): Boolean {
        val intent = context.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        ) ?: return false
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
    }
}
