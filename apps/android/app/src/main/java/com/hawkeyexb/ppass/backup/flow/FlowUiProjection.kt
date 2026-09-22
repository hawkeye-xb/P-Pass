// REBUILD-04: minimal, durable UI projection. WorkManager state is intentionally absent.
package com.hawkeyexb.ppass.backup.flow

sealed interface FlowUiState {
    data object Idle : FlowUiState
    data object PausedByUser : FlowUiState
    data object WaitingForConstraints : FlowUiState
    data class Transferring(val queueSequence: Long, val fileName: String = "") : FlowUiState
    /** The strict head exhausted its delivery attempts and needs an explicit retry. */
    data object NeedsUserAttention : FlowUiState
    data object CancelledCurrentRound : FlowUiState
}

/**
 * Maps only persisted ledger facts to the small R3 status surface. A user pause
 * wins over constraints; an active cancellation round is distinct from both.
 */
fun flowUiStateOf(snapshot: DiscoveryLedgerSnapshot): FlowUiState = when {
    snapshot.cancellationRound != null -> FlowUiState.CancelledCurrentRound
    snapshot.consumerGate == ConsumerGate.PAUSED_BY_USER -> FlowUiState.PausedByUser
    snapshot.consumerStatus == ConsumerStatus.WAITING_FOR_CONSTRAINTS -> FlowUiState.WaitingForConstraints
    else -> snapshot.items.firstOrNull { it.deliveryState == DeliveryState.TRANSFERRING }
        ?.let { FlowUiState.Transferring(it.queueSequence, it.fileName) }
        ?: snapshot.items.firstOrNull { it.deliveryState == DeliveryState.FAILED_NEEDS_USER }
            ?.let { FlowUiState.NeedsUserAttention }
        ?: FlowUiState.Idle
}

/**
 * UI-09: the home status bar's aggregate (pending K / confirmed M /
 * last-success) derived purely from durable ledger facts. The LEGACY
 * ConfirmedStore is not consulted anywhere on this path — the Flow core was
 * the only writer after REBUILD-00 froze the batch pipeline, so the old read
 * path froze the numbers on real devices (verifier observation, 2026-09-06).
 */
data class FlowAggregate(
    val pending: Long,
    val confirmed: Long,
    val lastSuccessAt: Long,
    /**
     * UI-16 规则 G4：账本里待用户处理的失败项条数。**全量口径，不随
     * [flowAggregateOf] 的 bucket 过滤收窄**——「有一张失败等着处理」在哪个
     * 相册都不是「数据已安全存好」，它是绿色的否决票，不是完成度的分子。
     */
    val failedNeedsUser: Long = 0L,
    /** UI-16 规则 G5：传输被用户按停（gate 语义由 #353/#362 定死，此处只读）。 */
    val pausedByUser: Boolean = false,
)

/**
 * UI-16: [bucketIds] = 当前选中相册（`null` = 全量，空集 = 一个都不备 → 0），
 * 与 `ConfirmedStore.countInScope` 同一范围口径。
 *
 * 为什么必须能过滤：英雄卡把这里的 `confirmed` 当分子、把
 * `MediaScanner.countAll(selectedBucketIds)` 当分母
 * （`BackupUiStateHolder.refreshTriplet`）。过滤之前分子是**账本全量**、
 * 分母是**选中相册的实时文件数**，两个集合既非包含关系也非同一单位，相除
 * 本就不成立——真机因此渲染出绿字「10 / 10 张已回家」（配对已失效 + 1 张
 * 失败）与「23 / 23 张已回家」（实有 4 张待传）。见
 * docs/design/2026-09-22-home-notice-priority.md §4.1。
 *
 * 默认 `null` 是有意的：状态行/进度条/前台服务那几个调用方要的就是全量，
 * 只有英雄卡的三元组按选中相册收窄。
 */
fun flowAggregateOf(
    snapshot: DiscoveryLedgerSnapshot,
    bucketIds: Set<Long>? = null,
): FlowAggregate {
    var pending = 0L
    var confirmed = 0L
    var lastSuccessAt = 0L
    var failedNeedsUser = 0L
    for (item in snapshot.items) {
        // G4 先数，再过滤——见 [FlowAggregate.failedNeedsUser] 的口径说明。
        if (item.deliveryState == DeliveryState.FAILED_NEEDS_USER) failedNeedsUser += 1
        if (bucketIds != null && item.bucketId !in bucketIds) continue
        when (item.deliveryState) {
            // A user-cancelled round is a deliberate decision, not a debt;
            // scope-cancelled items left the selected scope entirely. Neither
            // counts as "待备份".
            DeliveryState.QUEUED, DeliveryState.TRANSFERRING, DeliveryState.FAILED_NEEDS_USER -> pending += 1
            DeliveryState.CONFIRMED -> {
                confirmed += 1
                if (item.completedAt > lastSuccessAt) lastSuccessAt = item.completedAt
            }
            DeliveryState.CANCELLED_BY_SCOPE,
            DeliveryState.CANCELLED_BY_USER_ROUND,
            DeliveryState.SKIPPED_SOURCE_MISSING,
            -> Unit
        }
    }
    return FlowAggregate(
        pending = pending,
        confirmed = confirmed,
        lastSuccessAt = lastSuccessAt,
        failedNeedsUser = failedNeedsUser,
        pausedByUser = snapshot.consumerGate == ConsumerGate.PAUSED_BY_USER,
    )
}

/**
 * UI-09: "本轮全部安全" — every discovered item in the current durable window
 * carries a completion receipt and at least one item exists. An empty ledger
 * (nothing discovered yet) is deliberately NOT all-done; it renders Ready.
 *
 * UI-16 规则 S（§2.3b）：`SKIPPED_SOURCE_MISSING` **曾算作完成**，于是账本里
 * 有一张源已删除、永不重传的照片时，这里返回 true → [backupUiStateOf] 投影成
 * `AllSafe` → 状态行说「照片都存好了」，而同屏的 `flowMissingSourceNotice`
 * 正在说「已跳过 N 张…不会再重传」。那是英雄卡绿字谎言的文字版，同一个根因。
 * 「跳过」不是「存好了」：判据收紧成**每一项都有完成回执**。
 * （`CANCELLED_BY_USER_ROUND` 早就过不了这个 `all {}`，规则 S 的 S3 无需另加。）
 */
fun flowIsAllDone(snapshot: DiscoveryLedgerSnapshot, aggregate: FlowAggregate): Boolean =
    aggregate.confirmed > 0L && snapshot.items.all {
        it.deliveryState == DeliveryState.CONFIRMED
    }

/**
 * MOB-51: the durable round-active fact. A round is running while the gate
 * is open AND the ledger still owns deliverable work (a leased or queued
 * item). This survives the between-files gap that the per-file Transferring
 * projection cannot see (head confirmed, next queued, lease momentarily
 * null) — which made the Pause button practically unreachable on real
 * devices where LAN transfers finish a file in hundreds of milliseconds.
 * A user pause ends the round (paused shows Resume, not Pause); a terminal
 * failed head with no queued backing is "stalled", not "running" — showing
 * Pause there would lie about work happening.
 */
fun flowRoundActive(snapshot: DiscoveryLedgerSnapshot): Boolean =
    snapshot.consumerGate == ConsumerGate.OPEN &&
        (
            snapshot.fetchLease != null ||
                snapshot.items.any {
                    it.deliveryState == DeliveryState.QUEUED || it.deliveryState == DeliveryState.TRANSFERRING
                }
            )

/**
 * MOB-51: the single snapshot -> home-screen state mapping (shared by the
 * production holder and tests; production-chain rule). A round that is
 * active but momentarily between files still renders as work in progress,
 * so the Pause affordance stays reachable for the whole round. The gap
 * render is `Sending` with no file and total == 0 — the UI shows a plain
 * "round running" line, never a fabricated 0/0 or fake file progress.
 */
fun backupUiStateOf(snapshot: DiscoveryLedgerSnapshot): com.hawkeyexb.ppass.ui.BackupUiState {
    val aggregate = flowAggregateOf(snapshot)
    return when (val state = flowUiStateOf(snapshot)) {
        FlowUiState.Idle -> when {
            flowIsAllDone(snapshot, aggregate) ->
                com.hawkeyexb.ppass.ui.BackupUiState.AllSafe(ingested = aggregate.confirmed.toInt(), duplicates = 0)
            flowRoundActive(snapshot) ->
                com.hawkeyexb.ppass.ui.BackupUiState.Sending(
                    done = aggregate.confirmed.toInt(),
                    total = (aggregate.confirmed + aggregate.pending).toInt(),
                    currentFile = "",
                )
            else -> com.hawkeyexb.ppass.ui.BackupUiState.Idle
        }
        FlowUiState.PausedByUser -> com.hawkeyexb.ppass.ui.BackupUiState.Paused
        FlowUiState.WaitingForConstraints -> com.hawkeyexb.ppass.ui.BackupUiState.WaitingForConstraints
        is FlowUiState.Transferring -> com.hawkeyexb.ppass.ui.BackupUiState.Sending(
            done = aggregate.confirmed.toInt(),
            total = (aggregate.confirmed + aggregate.pending).toInt(),
            currentFile = state.fileName,
        )
        FlowUiState.NeedsUserAttention -> com.hawkeyexb.ppass.ui.BackupUiState.Trouble("Flow delivery exhausted its retry limit")
        FlowUiState.CancelledCurrentRound -> com.hawkeyexb.ppass.ui.BackupUiState.CancelledCurrentRound
    }
}

/** MOB-51: the durable command behind the single hero button click. */
enum class FlowCommand { Pause, Continue, Retry, Wake }

/**
 * MOB-51: routing the hero click on the SAME durable facts the button label
 * came from. Before this, the label said "Pause" in the between-files gap
 * while the click re-read the ledger, saw Idle, and fired a wake instead —
 * the button lied twice. Now a visible Pause click always pauses: an open
 * round with a lease, a transferring item, or a gap is pausable.
 */
fun flowCommandOf(snapshot: DiscoveryLedgerSnapshot): FlowCommand =
    when (flowUiStateOf(snapshot)) {
        FlowUiState.PausedByUser -> FlowCommand.Continue
        FlowUiState.NeedsUserAttention -> FlowCommand.Retry
        is FlowUiState.Transferring -> FlowCommand.Pause
        // Idle / WaitingForConstraints / CancelledCurrentRound: pause while
        // the round is durably active, otherwise wake a stopped engine.
        else -> if (flowRoundActive(snapshot)) FlowCommand.Pause else FlowCommand.Wake
    }

/**
 * UI-10 item 2: the reupload notice's LEGACY data source (`ReuploadQueue`)
 * is frozen (REBUILD-00) and `BackupUiStateHolder._reuploadNoticeCount` has
 * no production writer — `reuploadNoticeCount > 0` is permanently false, so
 * the notice card can never appear (source-read finding, 2026-09-06).
 *
 * The durable ledger already carries the exact fact this notice describes:
 * a CONFIRMED item whose remote copy went missing while the phone's own
 * source is still present (`RecoveryDisposition.NEEDS_DECISION`, written by
 * `RemoteReconciliation.recordRemoteMissing`) — that IS "library lost N,
 * bringing them back". Counting it directly retires the dead LEGACY path
 * without inventing a new signal.
 */
fun flowReuploadNoticeCount(snapshot: DiscoveryLedgerSnapshot): Int =
    snapshot.items.count { it.disposition == RecoveryDisposition.NEEDS_DECISION }

/** A phone-deleted source was skipped; it is informative and never retryable. */
data class MissingSourceNotice(val count: Int)

fun flowMissingSourceNotice(snapshot: DiscoveryLedgerSnapshot): MissingSourceNotice? {
    val count = snapshot.items.count {
        it.deliveryState == DeliveryState.SKIPPED_SOURCE_MISSING &&
            it.sourcePresence == SourcePresence.MISSING &&
            it.disposition == RecoveryDisposition.UNRECOVERABLE
    }
    return if (count > 0) MissingSourceNotice(count) else null
}

/**
 * MOB-59: the first cut only counted the *latest* round's items, so cancelling
 * twice without ever restoring silently orphaned the earlier batch — real
 * device: "重复点取消当前轮，已跳过 20 张的提示消失了，那批再也找不到"
 * (2026-09-07). This now sums every still-cancelled item across every round,
 * and the notice has no roundId of its own: [restoreAllCancelledFlowRounds]
 * (FlowRunner) restores every distinct cancelled round in one action, so the
 * UI never needs to track which specific round is "current".
 */
data class CancelledRoundNotice(val count: Int)

fun flowCancelledRoundNotice(snapshot: DiscoveryLedgerSnapshot): CancelledRoundNotice? {
    val count = snapshot.items.count {
        it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND && it.cancellationRoundId != null
    }
    return if (count > 0) CancelledRoundNotice(count) else null
}

/**
 * MOB-59: the progress bar must show *this round's* progress, not the
 * lifetime M/N the hero stat above it already shows — otherwise the two
 * numbers are a redundant echo of each other (user's own argument: adding
 * more albums mid-transfer made the bar jump to "15/15"-ish territory
 * instead of showing the newly-added work at 0, 2026-09-07). This is
 * inherently a *running* quantity (it needs to remember what was already
 * confirmed since the round started), so it cannot live in the pure
 * snapshot->state mapping ([backupUiStateOf]) the way K/M/N do — the holder
 * calls this once per tick and keeps the returned state itself.
 *
 * Rule: an item completing (pending drops) advances `done`; new pending
 * work materializing (album added mid-round, pending rises) only grows
 * `total` and never resets `done` — mid-round album additions do not lose
 * credit for what already finished. A round that fully drains (pending
 * hits 0) resets the baseline so the *next* round starts at a clean 0.
 */
data class RoundProgress(val done: Long, val total: Long)

fun advanceRoundProgress(previousPending: Long?, previousDone: Long, currentPending: Long): RoundProgress {
    val done = when {
        previousPending == null || previousPending == 0L -> 0L
        currentPending < previousPending -> previousDone + (previousPending - currentPending)
        else -> previousDone
    }
    return RoundProgress(done = done, total = done + currentPending)
}

/**
 * NET-12: REBUILD-04 (commit a325208) deleted `BackupWorker`'s
 * `setForeground()`/`ForegroundInfo` when it cut the worker down to a pure
 * wake adapter — the new Flow transport (`NativeFlowDeliveryPort`'s
 * coroutine `scope.launch`) never registered a replacement. Real device
 * (Samsung SM-S9210, 2026-09-14): `oom_score_adj` sampled every 10s during a
 * live 35-photo transfer stayed at 700-900 (cached-process range) the whole
 * time — the exact range the system killed the process from twice that same
 * day ("one-time permission revoked", adj=915 and adj=900). A foreground
 * service is the only thing that moves a process out of that range while
 * work is in flight.
 *
 * [flowRoundActive] is already the durable, ledger-derived fact for "is a
 * round in flight" (MOB-51). This is the pure decision the Android layer
 * dispatches on — never call platform Service APIs from here, so the
 * decision itself stays JVM-testable without a Robolectric/instrumented
 * harness.
 */
enum class ForegroundAction { START, STOP }

fun foregroundActionFor(snapshot: DiscoveryLedgerSnapshot): ForegroundAction =
    if (flowRoundActive(snapshot)) ForegroundAction.START else ForegroundAction.STOP

