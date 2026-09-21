// NET-12: the foreground service protection REBUILD-04 deleted (see
// FlowUiProjection.kt's foregroundActionFor doc for the full root-cause
// history and real-device evidence). This class only owns the Android
// Service lifecycle; the START/STOP decision itself is the pure,
// JVM-tested foregroundActionFor.
package com.hawkeyexb.ppass.backup.flow

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
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * MOB-101: what the last attempt to protect a running transfer actually
 * proved — deliberately the same three-way shape #299 (MOB-97) requires
 * of every "is background work really happening" verdict: only observed
 * evidence may say yes or no, and absence of evidence is [UNKNOWN], never
 * a reassuring [EFFECTIVE].
 */
enum class TransferProtection {
    /** A protected start succeeded — observed, not assumed. */
    EFFECTIVE,

    /** The system refused to protect the transfer and said why (daily budget). */
    NOT_EFFECTIVE,

    /** Never attempted, or refused for a reason we cannot name. */
    UNKNOWN,
}

/** MOB-101: the outcome of one attempt to put the transfer under protection. */
enum class ForegroundStartOutcome {
    STARTED,

    /**
     * Android 14+ gives a `dataSync` foreground service a cumulative
     * running budget (6h per 24h, reset when the user brings the app to
     * the foreground — developer.android.com/develop/background-work/
     * services/fgs/timeout). Spending it makes the very next protected
     * start throw; there is NO public API to ask how much is left, so
     * this is only ever learned after the fact.
     */
    SYSTEM_BUDGET_EXHAUSTED,

    /** Refused, but not with the budget reason — do not guess at a cause. */
    START_REFUSED,
}

@Serializable
data class TransferProtectionState(
    /** [ForegroundStartOutcome] name; empty = never attempted. */
    val lastOutcome: String = "",
    val lastOutcomeAt: Long = 0L,
)

/**
 * MOB-101: durable, single-fact store for the last protection outcome, so
 * the UI can read "the transfer is paused because the system stopped
 * protecting it" instead of showing a pause nobody asked for.
 * tmp+rename like every other store here; corrupt file reads as "never
 * attempted" (= UNKNOWN), which is the safe end of the tri-state.
 */
class TransferProtectionStore(private val dir: File) {
    private val file = File(dir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): TransferProtectionState =
        // MOB-102: a write that did not land means the file on disk is not
        // the current fact — and a stale "STARTED" would claim protection
        // works while we know it just failed. 写不进去就是不知道.
        if (file.absolutePath in unpersisted) {
            TransferProtectionState()
        } else if (file.isFile) {
            runCatching { json.decodeFromString<TransferProtectionState>(file.readText()) }
                .getOrDefault(TransferProtectionState())
        } else {
            TransferProtectionState()
        }

    /**
     * MOB-102: **this function must never throw.** It is only ever called
     * from the path that is already handling a failure, so escalating a
     * diagnostic write into a fatal is strictly worse than losing the
     * diagnosis — which is exactly what happened on the real device
     * (Samsung SM-S9210 / Android 15, 2026-09-21 17:25: two FATALs from
     * `check(tmp.renameTo(file))`, on `ppass-flow-wake` and on `main`).
     * [load] has said "unreadable = UNKNOWN = the safe end" since day one;
     * this is the symmetric half.
     *
     * The temp file is unique per call: two Flow wakes ran in the SAME
     * millisecond on two threads (real logcat), both renamed the one
     * fixed `.tmp` name, and the loser got `false` back. Uniqueness is
     * the actual fix for that race — never-throwing alone would only
     * downgrade it to "sometimes silently unrecorded".
     *
     * @return whether the outcome actually reached durable storage.
     */
    fun record(outcome: ForegroundStartOutcome, now: Long): Boolean {
        val state = TransferProtectionState(lastOutcome = outcome.name, lastOutcomeAt = now)
        val persisted = runCatching {
            dir.mkdirs()
            val tmp = File.createTempFile("$FILE_NAME.", ".tmp", dir)
            try {
                tmp.writeText(json.encodeToString(TransferProtectionState.serializer(), state))
                tmp.renameTo(file)
            } finally {
                tmp.delete()
            }
        }.getOrElse { failure ->
            logQuietly("cannot persist transfer protection state; the verdict stays UNKNOWN", failure)
            false
        }
        if (persisted) unpersisted.remove(file.absolutePath) else unpersisted.add(file.absolutePath)
        return persisted
    }

    private companion object {
        const val FILE_NAME = "flow-transfer-protection.json"

        /**
         * Paths whose last write did not land, so [load] must not serve
         * whatever stale fact is still on disk. Process-scoped on purpose:
         * a fresh process has no failed write of its own to remember.
         */
        val unpersisted: MutableSet<String> =
            java.util.Collections.synchronizedSet(mutableSetOf<String>())
    }
}

/** Logging must never be the thing that crashes a crash handler (and `Log` is a stub in JVM tests). */
private fun logQuietly(message: String, failure: Throwable? = null) {
    runCatching { Log.w("PPassFlow", message, failure) }
}

/** MOB-101: the pure verdict the UI reads. Evidence only — see [TransferProtection]. */
fun transferProtectionOf(state: TransferProtectionState): TransferProtection =
    when (state.lastOutcome) {
        ForegroundStartOutcome.STARTED.name -> TransferProtection.EFFECTIVE
        ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED.name -> TransferProtection.NOT_EFFECTIVE
        else -> TransferProtection.UNKNOWN
    }

/**
 * MOB-101: which plain-language line to show for the current pause, or
 * null when there is nothing to explain. Two distinct lines on purpose:
 * we may only say "today's time is used up" when the system actually said
 * so — a refusal we cannot explain gets its own honest wording.
 */
fun transferProtectionNoticeRes(state: TransferProtectionState): Int? =
    when (state.lastOutcome) {
        ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED.name -> R.string.state_background_budget_paused
        ForegroundStartOutcome.START_REFUSED.name -> R.string.state_background_protection_unknown
        else -> null
    }

/**
 * MOB-101: `ForegroundServiceStartNotAllowedException` is matched by NAME,
 * never by type. Two reasons: the class only exists from API 31, and the
 * JVM contract tests must be able to construct the failure without an
 * Android framework on the classpath.
 */
internal fun isForegroundStartRefusal(failure: Throwable): Boolean =
    failure.javaClass.simpleName == "ForegroundServiceStartNotAllowedException"

/**
 * MOB-101: the same exception type is thrown for plain background-start
 * denial, which is a different cause with different advice. Only the
 * system's own "Time limit already exhausted …" message proves the budget
 * reading, so the message is part of the discriminator.
 */
internal fun isSystemBudgetExhausted(failure: Throwable): Boolean =
    isForegroundStartRefusal(failure) && (failure.message ?: "").contains("Time limit")

/**
 * MOB-101: the one seam every protected start goes through. Kept free of
 * Android types so the contract is provable on the JVM (this repo has no
 * Robolectric; a `Service` cannot be instantiated in a unit test).
 */
internal fun startProtectedForeground(
    store: TransferProtectionStore,
    now: Long,
    haltTransfer: () -> Unit,
    start: () -> Unit,
): ForegroundStartOutcome {
    val outcome = try {
        start()
        ForegroundStartOutcome.STARTED
    } catch (refusal: IllegalStateException) {
        // Only a foreground-start refusal is handled here. Anything else
        // is a different fault and must stay visible — swallowing it
        // would bury the next bug the way the missing catch buried this
        // one.
        if (!isForegroundStartRefusal(refusal)) throw refusal
        if (isSystemBudgetExhausted(refusal)) {
            ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED
        } else {
            ForegroundStartOutcome.START_REFUSED
        }
    }
    // MOB-102: everything below is failure HANDLING. Whatever happens in
    // here, nothing may escape to `onStartCommand` / `flushAuditOutbox` —
    // this path exists to catch failures, so a failure of its own must
    // not become the next FATAL. (`start()`'s own unrecognized failure is
    // deliberately NOT covered by this: it is rethrown above, because
    // burying an unknown fault is the other way to lose a bug.)
    runCatching { store.record(outcome, now) }
        .onFailure { logQuietly("recording the protection outcome failed; continuing", it) }
    if (outcome != ForegroundStartOutcome.STARTED) {
        runCatching { haltTransfer() }
            .onFailure { logQuietly("pausing the round after a refused start failed", it) }
    }
    return outcome
}

/**
 * NET-12: keeps the transfer foreground service's running state in sync
 * with the durable "is a round active" ledger fact. Called from the same
 * postcondition point every Flow trigger already reaches
 * ([AndroidFlowRuntime]'s `flushAuditOutbox`), so it never depends on a
 * caller remembering to invoke it separately.
 */
internal object FlowTransferForeground {
    fun sync(context: Context, snapshot: DiscoveryLedgerSnapshot) {
        val app = context.applicationContext
        when (foregroundActionFor(snapshot)) {
            ForegroundAction.START -> {
                val intent = Intent(app, FlowTransferForegroundService::class.java)
                    .putExtra(FlowTransferForegroundService.EXTRA_TEXT, textFor(app, snapshot))
                startProtectedForeground(
                    store = TransferProtectionStore(app.filesDir),
                    now = System.currentTimeMillis(),
                    haltTransfer = { haltUnprotectedTransfer(app) },
                ) {
                    ContextCompat.startForegroundService(app, intent)
                }
            }
            ForegroundAction.STOP -> {
                app.stopService(Intent(app, FlowTransferForegroundService::class.java))
            }
        }
    }

    /** MOB-101: the plain-language line for the current pause, for the UI to read. */
    fun protectionNoticeRes(context: Context): Int? =
        transferProtectionNoticeRes(TransferProtectionStore(context.applicationContext.filesDir).load())

    /** MOB-101: the tri-state verdict (#299 alignment), for the UI to read. */
    fun protection(context: Context): TransferProtection =
        transferProtectionOf(TransferProtectionStore(context.applicationContext.filesDir).load())

    private fun textFor(context: Context, snapshot: DiscoveryLedgerSnapshot): String {
        val aggregate = flowAggregateOf(snapshot)
        val done = aggregate.confirmed.toInt()
        val total = (aggregate.confirmed + aggregate.pending).toInt()
        val currentFile = (flowUiStateOf(snapshot) as? FlowUiState.Transferring)?.fileName.orEmpty()
        return if (currentFile.isNotEmpty()) {
            context.getString(R.string.state_sending_file, currentFile, done, total)
        } else {
            context.getString(R.string.state_sending, done, total)
        }
    }
}

/**
 * MOB-101: losing protection must NOT become "keep sending anyway". That
 * is exactly the pre-NET-12 state (process reclaimed mid-round, half a
 * round silently stops), i.e. trading a crash for a silent failure. The
 * durable Flow pause is the honest answer: the round stops where it is
 * and the ledger keeps every fact, so continuing later loses nothing.
 *
 * Who resumes, and on what trigger: the user. `pauseFlow` leaves the
 * hero button on 继续/Continue, and tapping it necessarily means the app
 * is on screen — which is precisely the condition Android documents as
 * resetting the `dataSync` budget timer, and the condition under which a
 * transfer needs no background protection at all. No timer, no polling,
 * no automatic retry into the same exception.
 */
private fun haltUnprotectedTransfer(context: Context) {
    Log.w("PPassFlow", "transfer protection unavailable; pausing the round instead of sending unprotected")
    pauseFlow(context.applicationContext)
}

/**
 * MOB-08's real-device lesson still applies here: WorkManager's own FGS
 * declares `foregroundServiceType="dataSync"` in the manifest — this
 * service must match it or `startForeground(DATA_SYNC)` crashes on
 * Android 14 (T-054b crash history).
 */
class FlowTransferForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        val notification = buildNotification(text)
        val outcome = startProtectedForeground(
            store = TransferProtectionStore(filesDir),
            now = System.currentTimeMillis(),
            haltTransfer = { haltUnprotectedTransfer(this) },
        ) {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }
        if (outcome != ForegroundStartOutcome.STARTED) {
            // We were started with startForegroundService() and owe the
            // system a startForeground() within ~5s; failing to discharge
            // that obligation is its own fatal
            // (ForegroundServiceDidNotStartInTimeException). stopSelf()
            // discharges it.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /**
     * MOB-101 (sibling of the start-path crash): on Android 15 the budget
     * can also run out while this service is already running. The system
     * then calls this and expects the service gone within seconds —
     * missing that deadline is its own fatal. Same evidence, same pause,
     * same plain-language line.
     */
    @androidx.annotation.RequiresApi(35)
    override fun onTimeout(startId: Int, fgsType: Int) {
        TransferProtectionStore(filesDir)
            .record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, System.currentTimeMillis())
        haltUnprotectedTransfer(this)
        stopSelf()
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.notif_channel_transfer),
                    NotificationManager.IMPORTANCE_LOW, // silent — this is status, not an alert
                ),
            )
        }
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notif_transfer_title))
            .setContentText(text.ifEmpty { getString(R.string.notif_transfer_title) })
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setContentIntent(pi)
        return builder.build()
    }

    companion object {
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "ppass.backup.transfer"
        private const val NOTIFICATION_ID = 2026
    }
}
