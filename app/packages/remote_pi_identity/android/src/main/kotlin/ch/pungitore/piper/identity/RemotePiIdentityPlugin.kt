package ch.pungitore.piper.identity

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Bridges the Dart `OwnerIdentityStore` API to Block Store.
 *
 * Channels:
 *  - Method: `remote_pi_identity` (load / save / delete / isSyncAvailable)
 *  - Event:  `remote_pi_identity/events` (blob updates)
 *
 * All Block Store calls run on a single-threaded background executor —
 * `Tasks.await()` is synchronous and we don't want to pin the Flutter
 * platform thread. Results are marshalled back to the main thread
 * before invoking the Dart-side callbacks (MethodChannel.Result and
 * EventChannel.EventSink both require main-thread access).
 */
class RemotePiIdentityPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var store: BlockStoreStore

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var lastEmittedBlob: ByteArray? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context: Context = binding.applicationContext
        store = BlockStoreStore(context)

        methodChannel = MethodChannel(binding.binaryMessenger, "remote_pi_identity")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "remote_pi_identity/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> runOnExecutor(result) {
                if (!store.isSyncAvailable()) {
                    throw BlockStoreStore.Error.SyncUnavailable(
                        "Google Backup / Block Store is not available on this device"
                    )
                }
                store.load()
            }

            "save" -> {
                val blob = call.argument<ByteArray>("blob")
                if (blob == null) {
                    result.error(
                        "bad_args",
                        "save: expected { blob: Uint8List }",
                        null
                    )
                    return
                }
                runOnExecutor(result) {
                    if (!store.isSyncAvailable()) {
                        throw BlockStoreStore.Error.SyncUnavailable(
                            "Google Backup / Block Store is not available on this device"
                        )
                    }
                    store.save(blob)
                    // Echo to the watch stream — UI that subscribes to
                    // watch() exclusively sees its own write.
                    mainHandler.post { emitIfChanged(blob) }
                    null
                }
            }

            "delete" -> runOnExecutor(result) {
                store.delete()
                lastEmittedBlob = null
                null
            }

            "isSyncAvailable" -> runOnExecutor(result) {
                store.isSyncAvailable()
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        // Initial emit if we already have a blob — saves callers from
        // having to call load() and listen() separately.
        executor.execute {
            try {
                if (store.isSyncAvailable()) {
                    val data = store.load()
                    if (data != null) {
                        mainHandler.post { emitIfChanged(data) }
                    }
                }
            } catch (_: Throwable) {
                // Initial-emit best-effort. Real errors come through
                // load()/save() over the method channel.
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitIfChanged(blob: ByteArray) {
        val previous = lastEmittedBlob
        if (previous != null && previous.contentEquals(blob)) return
        lastEmittedBlob = blob
        eventSink?.success(blob)
    }

    private inline fun <T> runOnExecutor(
        result: MethodChannel.Result,
        crossinline block: () -> T
    ) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: BlockStoreStore.Error.SyncUnavailable) {
                mainHandler.post {
                    result.error("sync_unavailable", e.reason, null)
                }
            } catch (e: BlockStoreStore.Error.Platform) {
                mainHandler.post {
                    result.error(e.errorCode, e.message, null)
                }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("unknown", t.message ?: "unknown error", null)
                }
            }
        }
    }
}
