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
data class FlowAggregate(val pending: Long, val confirmed: Long, val lastSuccessAt: Long)

fun flowAggregateOf(snapshot: DiscoveryLedgerSnapshot): FlowAggregate {
    var pending = 0L
    var confirmed = 0L
    var lastSuccessAt = 0L
    for (item in snapshot.items) {
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
    return FlowAggregate(pending = pending, confirmed = confirmed, lastSuccessAt = lastSuccessAt)
}

/**
 * UI-09: "本轮全部安全" — every discovered item in the current durable window
 * carries a completion receipt and at least one item exists. An empty ledger
 * (nothing discovered yet) is deliberately NOT all-done; it renders Ready.
 */
fun flowIsAllDone(snapshot: DiscoveryLedgerSnapshot, aggregate: FlowAggregate): Boolean =
    aggregate.confirmed > 0L && snapshot.items.all {
        it.deliveryState == DeliveryState.CONFIRMED ||
            it.deliveryState == DeliveryState.SKIPPED_SOURCE_MISSING
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

