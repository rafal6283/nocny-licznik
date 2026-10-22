package pl.rafal.bakometr_native

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * Zapis nocy do Health Connect jako sesji snu z fazami.
 * Inne aplikacje (np. Life Cycle, Google Fit/Fitbit) czytają je stamtąd.
 * clientRecordId = stały identyfikator nocy, więc ponowny zapis aktualizuje zamiast dublować.
 */
class HealthSync(private val ctx: Context) : PluginRegistry.ActivityResultListener {
    companion object {
        private const val TAG = "BakometrHC"
        private const val REQ = 4711
        private const val PROVIDER = "com.google.android.apps.healthdata"
        val PERMS = setOf(HealthPermission.getWritePermission(SleepSessionRecord::class))
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var pending: MethodChannel.Result? = null

    /** Zwraca true, gdy metoda należy do Health Connect. */
    fun handle(call: MethodCall, result: MethodChannel.Result, activity: Activity?): Boolean {
        when (call.method) {
            "hcStatus" -> result.success(status())
            "hcHasPermission" -> scope.launch { result.success(granted()) }
            "hcRequestPermission" -> request(activity, result)
            "hcWriteSleep" -> {
                val nights = call.argument<List<Map<String, Any?>>>("nights") ?: emptyList()
                scope.launch { result.success(write(nights)) }
            }
            else -> return false
        }
        return true
    }

    private fun status(): String = when (HealthConnectClient.getSdkStatus(ctx, PROVIDER)) {
        HealthConnectClient.SDK_AVAILABLE -> "available"
        HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "update"
        else -> "unavailable"
    }

    private suspend fun granted(): Boolean = try {
        status() == "available" &&
            HealthConnectClient.getOrCreate(ctx).permissionController.getGrantedPermissions().containsAll(PERMS)
    } catch (e: Exception) {
        Log.w(TAG, "Sprawdzenie uprawnień", e)
        false
    }

    private fun request(activity: Activity?, result: MethodChannel.Result) {
        when (status()) {
            "update" -> {
                // Android 9–13: aplikacja Health Connect do zainstalowania/aktualizacji ze Sklepu Play.
                try {
                    val uri = Uri.parse("market://details?id=$PROVIDER&url=healthconnect%3A%2F%2Fonboarding")
                    val i = Intent(Intent.ACTION_VIEW, uri).setPackage("com.android.vending")
                    (activity ?: ctx).startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (e: Exception) {
                    Log.w(TAG, "Sklep Play", e)
                }
                result.success(false)
                return
            }
            "unavailable" -> {
                result.success(false)
                return
            }
        }
        scope.launch {
            if (granted()) {
                result.success(true)
                return@launch
            }
            if (activity == null) {
                result.success(false)
                return@launch
            }
            pending?.success(false)
            pending = result
            val intent = PermissionController.createRequestPermissionResultContract().createIntent(activity, PERMS)
            activity.startActivityForResult(intent, REQ)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ) return false
        val r = pending ?: return true
        pending = null
        scope.launch { r.success(granted()) }
        return true
    }

    private fun offset(t: Instant): ZoneOffset = ZoneId.systemDefault().rules.getOffset(t)

    private fun stageType(s: String?): Int = when (s) {
        "wake" -> SleepSessionRecord.STAGE_TYPE_AWAKE
        "light" -> SleepSessionRecord.STAGE_TYPE_LIGHT
        "deep" -> SleepSessionRecord.STAGE_TYPE_DEEP
        "rem" -> SleepSessionRecord.STAGE_TYPE_REM
        else -> SleepSessionRecord.STAGE_TYPE_SLEEPING
    }

    private fun ms(v: Any?): Long? = (v as? Number)?.toLong()

    /** Zapisuje noce; zwraca liczbę zapisanych albo -1 przy błędzie/braku uprawnień. */
    private suspend fun write(nights: List<Map<String, Any?>>): Int {
        if (!granted()) return -1
        val version = System.currentTimeMillis()
        val records = nights.mapNotNull { n ->
            val s = ms(n["start"]) ?: return@mapNotNull null
            val e = ms(n["end"]) ?: return@mapNotNull null
            val id = n["id"] as? String ?: return@mapNotNull null
            if (e - s < 60_000L) return@mapNotNull null
            val stages = (n["stages"] as? List<*>).orEmpty().mapNotNull { st ->
                val m = st as? Map<*, *> ?: return@mapNotNull null
                val a = maxOf(ms(m["start"]) ?: return@mapNotNull null, s)
                val b = minOf(ms(m["end"]) ?: return@mapNotNull null, e)
                if (b <= a) null
                else SleepSessionRecord.Stage(Instant.ofEpochMilli(a), Instant.ofEpochMilli(b), stageType(m["stage"] as? String))
            }
            val start = Instant.ofEpochMilli(s)
            val end = Instant.ofEpochMilli(e)
            SleepSessionRecord(
                startTime = start,
                startZoneOffset = offset(start),
                endTime = end,
                endZoneOffset = offset(end),
                title = n["title"] as? String,
                notes = n["notes"] as? String,
                stages = stages,
                metadata = Metadata(clientRecordId = id, clientRecordVersion = version),
            )
        }
        if (records.isEmpty()) return 0
        return try {
            val client = HealthConnectClient.getOrCreate(ctx)
            records.chunked(50).forEach { client.insertRecords(it) }
            records.size
        } catch (e: Exception) {
            Log.w(TAG, "Zapis snu do Health Connect", e)
            -1
        }
    }
}
