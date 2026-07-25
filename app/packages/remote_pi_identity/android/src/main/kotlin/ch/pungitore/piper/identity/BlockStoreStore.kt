package ch.pungitore.piper.identity

import android.app.KeyguardManager
import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.BlockstoreClient
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks

/**
 * Wraps Block Store. Stores a single blob keyed by [BLOB_KEY] with
 * `setShouldBackupToCloud(true)` so it travels to other devices of the
 * same Google account via the Google Backup pipeline.
 *
 * Key things to know about Block Store:
 *
 * - Total budget per app is small (~1KB across all keys). The serialized
 *   `OwnerIdentity` blob is sized to fit within this with margin.
 * - There is no "value changed" callback. Live sync between two
 *   currently-active devices is not supported — Block Store only flows
 *   on restore-to-new-device. The Dart-side `watch()` falls back to
 *   foreground polling (handled in the plugin class).
 * - `isDeviceSecure()` (lock screen set) is required by Block Store at
 *   runtime; we surface that as part of [isSyncAvailable].
 */
class BlockStoreStore(private val context: Context) {

    sealed class Error : Throwable() {
        class SyncUnavailable(val reason: String) : Error()
        class Platform(val errorCode: String, override val message: String) : Error()
    }

    private val client: BlockstoreClient by lazy { Blockstore.getClient(context) }

    fun load(): ByteArray? {
        val request = RetrieveBytesRequest.Builder()
            .setKeys(listOf(BLOB_KEY))
            .build()
        val response = awaitTask(client.retrieveBytes(request))
        val entry = response.blockstoreDataMap[BLOB_KEY] ?: return null
        // Block Store returns an empty byte array when the key was
        // written but cleared; treat as "no value".
        return if (entry.bytes.isEmpty()) null else entry.bytes
    }

    fun save(blob: ByteArray) {
        val data = StoreBytesData.Builder()
            .setBytes(blob)
            .setKey(BLOB_KEY)
            .setShouldBackupToCloud(true)
            .build()
        awaitTask(client.storeBytes(data))
    }

    fun delete() {
        val request = DeleteBytesRequest.Builder()
            .setKeys(listOf(BLOB_KEY))
            .build()
        awaitTask(client.deleteBytes(request))
    }

    /**
     * Whether Block Store + cloud backup look usable. Three conditions:
     *  1. Google Play services available on device.
     *  2. Lock screen configured (required by Block Store at write time).
     *  3. The Block Store API is reachable — confirmed by a lightweight
     *     `retrieveBytes` call. We can't directly query "is Google
     *     Backup on?" — that surfaces as the retrieve task failing.
     */
    fun isSyncAvailable(): Boolean {
        val play = GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(context)
        if (play != ConnectionResult.SUCCESS) return false

        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard?.isDeviceSecure != true) return false

        // Reachability probe: a retrieve always succeeds when the API
        // is wired up, even if the key is missing.
        return try {
            val request = RetrieveBytesRequest.Builder()
                .setKeys(listOf(BLOB_KEY))
                .build()
            awaitTask(client.retrieveBytes(request))
            true
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Blocks the calling thread for the GMS task. The plugin calls this
     * from a background executor so the Flutter platform thread isn't
     * pinned. Throws [Error.Platform] on failure.
     */
    private fun <T> awaitTask(task: Task<T>): T {
        return try {
            Tasks.await(task)
        } catch (t: Throwable) {
            throw Error.Platform(
                errorCode = "blockstore_error",
                message = t.message ?: "Block Store task failed"
            )
        }
    }

    companion object {
        private const val BLOB_KEY = "ch.pungitore.piper.owner.identity"
    }
}
