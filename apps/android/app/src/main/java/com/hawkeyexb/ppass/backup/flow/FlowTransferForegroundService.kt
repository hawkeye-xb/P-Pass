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
        if (file.isFile) {
            runCatching { json.decodeFromString<TransferProtectionState>(file.readText()) }
                .getOrDefault(TransferProtectionState())
        } else {
            TransferProtectionState()
        }

    /** @return whether the outcome actually reached durable storage. */
    fun record(outcome: ForegroundStartOutcome, now: Long): Boolean {
        dir.mkdirs()
        val state = TransferProtectionState(lastOutcome = outcome.name, lastOutcomeAt = now)
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(json.encodeToString(TransferProtectionState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist transfer protection state" }
        return true
    }

    private companion object {
        const val FILE_NAME = "flow-transfer-protection.json"
    }
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
    store.record(outcome, now)
    if (outcome != ForegroundStartOutcome.STARTED) haltTransfer()
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
