package pl.rafal.bakometr_native

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import kotlin.reflect.KClass
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

        /** Odczyt danych z zegarka (np. Huawei przez Health Sync): tętno, SpO₂, sen z fazami. */
        val READ_PERMS = setOf(
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(OxygenSaturationRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class),
        )
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var pending: MethodChannel.Result? = null

    /** Zwraca true, gdy metoda należy do Health Connect. */
    fun handle(call: MethodCall, result: MethodChannel.Result, activity: Activity?): Boolean {
        when (call.method) {
            "hcStatus" -> result.success(status())
            "hcHasPermission" -> scope.launch { result.success(granted()) }
            "hcRequestPermission" -> request(activity, result, PERMS)
            "hcHasReadPermission" -> scope.launch { result.success(granted(READ_PERMS)) }
            "hcRequestReadPermission" -> request(activity, result, READ_PERMS)
            "hcReadNight" -> {
                val from = (call.argument<Number>("start"))?.toLong() ?: 0L
                val to = (call.argument<Number>("end"))?.toLong() ?: 0L
                scope.launch { result.success(readNight(from, to)) }
            }
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

    private suspend fun granted(perms: Set<String> = PERMS): Boolean = try {
        status() == "available" &&
            HealthConnectClient.getOrCreate(ctx).permissionController.getGrantedPermissions().containsAll(perms)
    } catch (e: Exception) {
        Log.w(TAG, "Sprawdzenie uprawnień", e)
        false
    }

    private var pendingPerms: Set<String> = PERMS

    private fun request(activity: Activity?, result: MethodChannel.Result, perms: Set<String>) {
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
            if (granted(perms)) {
                result.success(true)
                return@launch
            }
            if (activity == null) {
                result.success(false)
                return@launch
            }
            pending?.success(false)
            pending = result
            pendingPerms = perms
            val intent = PermissionController.createRequestPermissionResultContract().createIntent(activity, perms)
            activity.startActivityForResult(intent, REQ)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ) return false
        val r = pending ?: return true
        pending = null
        val perms = pendingPerms
        scope.launch { r.success(granted(perms)) }
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

    /** Wszystkie strony rekordów danego typu z przedziału czasu. */
    private suspend fun <T : Record> readAll(client: HealthConnectClient, type: KClass<T>, from: Instant, to: Instant): List<T> {
        val out = ArrayList<T>()
        var token: String? = null
        do {
            val resp = client.readRecords(
                ReadRecordsRequest(type, TimeRangeFilter.between(from, to), pageSize = 1000, pageToken = token)
            )
            out += resp.records
            token = resp.pageToken
        } while (token != null && out.size < 20_000)
        return out
    }

    private fun stageName(t: Int): String = when (t) {
        1, 3, 7 -> "wake" // czuwanie, poza łóżkiem, czuwanie w łóżku
        SleepSessionRecord.STAGE_TYPE_LIGHT -> "light"
        SleepSessionRecord.STAGE_TYPE_DEEP -> "deep"
        SleepSessionRecord.STAGE_TYPE_REM -> "rem"
        else -> "sleep"
    }

    /**
     * Dane z zegarka dla nocy [from, to] (ms). Pomija rekordy zapisane przez tę aplikację.
     * Zwraca: {hr: [[ms, bpm]], spo2: [[ms, %]], stages: [[start, end, stage]], sources: [pakiety]}
     * albo null przy braku zgody / błędzie.
     */
    private suspend fun readNight(fromMs: Long, toMs: Long): Map<String, Any?>? {
        if (toMs <= fromMs || !granted(READ_PERMS)) return null
        val from = Instant.ofEpochMilli(fromMs)
        val to = Instant.ofEpochMilli(toMs)
        val me = ctx.packageName
        return try {
            val client = HealthConnectClient.getOrCreate(ctx)
            val sources = LinkedHashSet<String>()

            val hr = ArrayList<List<Number>>()
            for (r in readAll(client, HeartRateRecord::class, from, to)) {
                val pkg = r.metadata.dataOrigin.packageName
                if (pkg == me) continue
                sources += pkg
                for (smp in r.samples) {
                    val t = smp.time.toEpochMilli()
                    if (t in fromMs..toMs) hr.add(listOf(t, smp.beatsPerMinute))
                }
            }
            hr.sortBy { it[0].toLong() }

            val spo2 = ArrayList<List<Number>>()
            for (r in readAll(client, OxygenSaturationRecord::class, from, to)) {
                val pkg = r.metadata.dataOrigin.packageName
                if (pkg == me) continue
                sources += pkg
                spo2.add(listOf(r.time.toEpochMilli(), r.percentage.value))
            }
            spo2.sortBy { it[0].toLong() }

            // Sesje snu nachodzące na noc (mogą zacząć się przed startem nagrania)
            val stages = ArrayList<List<Any>>()
            val pad = java.time.Duration.ofHours(3)
            for (r in readAll(client, SleepSessionRecord::class, from.minus(pad), to.plus(pad))) {
                val pkg = r.metadata.dataOrigin.packageName
                if (pkg == me) continue
                if (r.endTime.toEpochMilli() <= fromMs || r.startTime.toEpochMilli() >= toMs) continue
                sources += pkg
                if (r.stages.isEmpty()) {
                    stages.add(listOf(r.startTime.toEpochMilli(), r.endTime.toEpochMilli(), "sleep"))
                } else {
                    for (st in r.stages) stages.add(listOf(st.startTime.toEpochMilli(), st.endTime.toEpochMilli(), stageName(st.stage)))
                }
            }
            stages.sortBy { (it[0] as Long) }

            mapOf("hr" to hr, "spo2" to spo2, "stages" to stages, "sources" to sources.toList())
        } catch (e: Exception) {
            Log.w(TAG, "Odczyt z Health Connect", e)
            null
        }
    }
}
