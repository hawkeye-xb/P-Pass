// ARCH-02: durable phone-side facts for discovery admission.
// A page of candidates and its DiscoveryCursor always live in one snapshot:
// write a replacement file, then atomically rename it into place.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import java.util.UUID
import kotlinx.serialization.Serializable

@Serializable
data class DiscoveryCursor(
    val lastGeneration: Long,
    val lastMediaId: Long,
) {
    companion object {
        val INITIAL = DiscoveryCursor(lastGeneration = 0L, lastMediaId = 0L)
    }
}

@Serializable
data class ScopeRevision(val value: Long = 1L)

@Serializable
data class PairingEpoch(val value: String) {
    companion object {
        val INITIAL = PairingEpoch("")
    }
}

@Serializable
data class CancellationRound(val id: String)

// AUDIT-01: audit_event v2 is the sole long-term audit source. A phone-side
// fact that must be audited is written into this durable outbox in the SAME
// atomic snapshot as the fact itself — never as a separate "append after
// commit" step, which is exactly the crash window this replaces (see card).
// The event id is generated once and persists; it is the idempotency key the
// Desktop repository uniques on, so retransmission never duplicates.
object AuditKinds {
    const val ROUND_CONTROLLED = "flow.round.controlled"
    const val SCOPE_CHANGED = "flow.scope.changed"
    const val EPOCH_INVALIDATED = "flow.epoch.invalidated"
    const val ROUND_FINISHED = "flow.round.finished"
    const val ITEM_ATTENTION = "flow.item.attention"
    const val RECONCILIATION_RESOLVED = "flow.reconciliation.resolved"
    /** AUDIT-04: per-item confirmation evidence, generated in the same
     *  atomic snapshot as [CompletionAndScope.acceptCompletionReceipt] —
     *  the durable "object证据" a `flow.round.finished` summary must be
     *  able to point to (card acceptance criterion #1/#2). Never
     *  projected to the activity page (normal success is not long-term
     *  activity noise); only queryable through the operation it belongs to. */
    const val ITEM_CONFIRMED = "flow.item.confirmed"
    /** AUDIT-04: a discovered source vanished before it could be sent
     *  (case matrix §3 "有源图消失"). Previously this terminal fact wrote
     *  no audit trail at all — [StrictConsumer.skipMissingSource] now
     *  emits this in the same atomic snapshot as the state transition. */
    const val ITEM_SOURCE_MISSING = "flow.item.source_missing"

    /**
     * MOB-87: 对账本该有活干、却一条都没排进核对页。
     *
     * `ReconciliationCoordinator` 原本在这种情况下裸 `return`——调用方拿到的
     * 「对完账了，全都在」和「一条都没对上」是同一个返回值。账本里明明有
     * CONFIRMED 项却排不出核对页，只可能是筛选判据坏了（最典型的是账本项
     * 的 `pairingEpoch` 没跟上 snapshot），**那是故障，不是"没事可做"**。
     *
     * 不抛异常：对账是收敛手段，一轮失败等下一轮，不能把备份搞停
     * （同 daemon 侧 `reconcile.rs:125` 的纪律）。留痕而已。
     *
     * ⚠️ 这条**只**给「有 CONFIRMED 但页为空」用。桌面离线导致探测失败是
     * 另一回事，那种情况直接等下一轮，不许往这里刷。
     */
    const val RECONCILIATION_STALLED = "flow.reconciliation.stalled"

    /**
     * MOB-88: 一条异步送来的事实，其依据在落地时已经不成立，被 reducer 拒绝。
     *
     * 为什么要留这条：回执/失败/哈希回填这些事实来自原生传输线程，到达时
     * 世界可能已经变了（用户暂停了、该轮被取消了、桌面端换了配对代号、
     * 账本被重置了）。改造前这些情况一律静默 `return`——系统不出声，于是
     * #107 的真机验收根本问不出结果（撤掉锁的对照组和修复版日志一模一样）。
     * 留痕是把「静默竞态」变成「可发现问题」的唯一手段。
     *
     * payload：`action`（哪条事实）、`reason`（哪个前提不成立）、可选
     * `queueSequence`。桌面端 `audit_route` 对未知 kind 走
     * `route_unknown_as_operation`，所以新增这个类型不需要动协议或桌面端。
     */
    const val ACTION_REJECTED = "flow.action.rejected"
}

@Serializable
data class AuditOutboxEvent(
    val eventId: String,
    val kind: String,
    val roundId: String? = null,
    val occurredAtMs: Long = 0L,
    val payload: Map<String, String> = emptyMap(),
)

/**
 * AUDIT-01: append one durable outbox event to this snapshot. Callers pass
 * the pre-mutation `this` receiver from inside a `ledger.update { ... }`
 * transform, so the audit fact commits in the exact same atomic write as the
 * state change it describes — never a second, separate write.
 */
internal fun DiscoveryLedgerSnapshot.appendAudit(
    kind: String,
    roundId: String? = null,
    payload: Map<String, String> = emptyMap(),
): DiscoveryLedgerSnapshot = copy(
    auditOutbox = auditOutbox + AuditOutboxEvent(
        eventId = UUID.randomUUID().toString(),
        kind = kind,
        roundId = roundId,
        occurredAtMs = System.currentTimeMillis(),
        payload = payload,
    ),
)

/**
 * MOB-88: 记一条「这条事实的依据已经不成立，被拒绝了」。
 *
 * 与 [appendAudit] 同样在 reducer 的那次原子写里提交——拒绝本身就是一个
 * 事实，不是一次无事发生。
 */
internal fun DiscoveryLedgerSnapshot.rejected(
    action: String,
    reason: String,
    queueSequence: Long? = null,
): DiscoveryLedgerSnapshot = appendAudit(
    AuditKinds.ACTION_REJECTED,
    roundId = currentRoundId,
    payload = buildMap {
        put("action", action)
        put("reason", reason)
        queueSequence?.let { put("queueSequence", it.toString()) }
    },
)

/**
 * MOB-88: 哈希回填的状态迁移，抽成纯函数以便直接测。
 *
 * 哈希是在写者线程之外算的（4GB 视频要把 4GB 读完），算完回来时这一条
 * 可能已经不是租约持有者了——暂停、取消、代号更换都会收走租约。这时候把
 * 整条 item 副本写回去，就会把它们刚做的状态迁移按回旧值：`StrictConsumer`
 * 里 2026-09-16 那条真机注释记的就是这类覆盖（TRANSFERRING 被写回 QUEUED）。
 */
internal fun DiscoveryLedgerSnapshot.withContentHash(item: TransferItem): DiscoveryLedgerSnapshot {
    val lease = fetchLease
    if (lease == null || lease.queueSequence != item.queueSequence) {
        return rejected("content_hash", "no_longer_the_leased_head", item.queueSequence)
    }
    if (items.none { it.queueSequence == item.queueSequence }) {
        return rejected("content_hash", "item_no_longer_in_ledger", item.queueSequence)
    }
    return copy(items = items.map { if (it.queueSequence == item.queueSequence) item else it })
}

@Serializable
data class UploadCursor(val currentQueueSequence: Long? = null) {
    companion object {
        val INITIAL = UploadCursor()
    }
}

@Serializable
enum class ConsumerGate {
    OPEN,
    PAUSED_BY_USER,
}

@Serializable
enum class ConsumerStatus {
    IDLE,
    WAITING_FOR_CONSTRAINTS,
}

@Serializable
data class FetchLease(
    val queueSequence: Long,
    val leaseToken: String,
)

enum class DeliveryState {
    QUEUED,
    TRANSFERRING,
    FAILED_NEEDS_USER,
    CONFIRMED,
    /** The phone source vanished after discovery; no retry can recover it. */
    SKIPPED_SOURCE_MISSING,
    CANCELLED_BY_SCOPE,
    CANCELLED_BY_USER_ROUND,
}

@Serializable
enum class RemotePresence {
    UNKNOWN,
    PRESENT,
    MISSING,
}

@Serializable
enum class SourcePresence {
    UNKNOWN,
    PRESENT,
    MISSING,
}

@Serializable
enum class RecoveryDisposition {
    NONE,
    NEEDS_DECISION,
    UNRECOVERABLE,
}

@Serializable
data class DiscoveryCandidate(
    val sourceRef: String,
    val sourceVersion: String,
    val bucketId: Long,
    val fileName: String = "",
    val mediaType: String = "application/octet-stream",
    // DESK-12: MediaStore DATE_TAKEN as unix ms (0 = unknown/not queried).
    // Carried through to Desktop only as a fallback for files with no EXIF
    // — content that has EXIF keeps using it, unaffected by this field.
    val captureAtMs: Long = 0L,
) {
    val stableId: String
        get() = "$sourceRef\u0000$sourceVersion"
}

@Serializable
data class TransferItem(
    val stableId: String,
    val sourceRef: String,
    val sourceVersion: String,
    val bucketId: Long,
    val fileName: String = "",
    val mediaType: String = "application/octet-stream",
    val scopeRevision: ScopeRevision,
    val queueSequence: Long,
    val deliveryState: DeliveryState,
    val attemptCount: Int = 0,
    val partialRetained: Boolean = false,
    val completionReceiptId: String? = null,
    val contentHash: String? = null,
    val remotePresence: RemotePresence = RemotePresence.UNKNOWN,
    val sourcePresence: SourcePresence = SourcePresence.UNKNOWN,
    val disposition: RecoveryDisposition = RecoveryDisposition.NONE,
    val cancellationRoundId: String? = null,
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    /** UI-09: unix ms of the durable completion receipt (0 = never completed). */
    val completedAt: Long = 0L,
    /** DESK-12: MediaStore DATE_TAKEN as unix ms (0 = unknown), admitted from
     *  the discovering [DiscoveryCandidate.captureAtMs]. Sent on the wire so
     *  Desktop can use it as a fallback when the file has no EXIF. */
    val captureAtMs: Long = 0L,
    /** AUDIT-01: the persistent window this item was admitted into. Every
     *  ordinary window gets exactly one `flow.round.finished` summary keyed
     *  by this id once every item in the round reaches a terminal state. */
    val roundId: String? = null,
)

@Serializable
data class ScopeBackfillRequest(
    val scopeRevision: ScopeRevision,
    /** Progress within the historical scan; never replaces the live discovery cursor. */
    val cursor: DiscoveryCursor = DiscoveryCursor.INITIAL,
    /** Immutable upper bound captured when the scope grew. */
    val boundary: DiscoveryCursor = DiscoveryCursor.INITIAL,
)

@Serializable
data class DiscoveryLedgerSnapshot(
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    /** Trigger coalescing fact. Only the Flow runner consumes it into discovery. */
    val discoveryRequested: Boolean = false,
    val cursor: DiscoveryCursor = DiscoveryCursor.INITIAL,
    val scopeRevision: ScopeRevision = ScopeRevision(),
    val cancellationRound: CancellationRound? = null,
    val uploadCursor: UploadCursor = UploadCursor.INITIAL,
    val consumerGate: ConsumerGate = ConsumerGate.OPEN,
    val consumerStatus: ConsumerStatus = ConsumerStatus.IDLE,
    val fetchLease: FetchLease? = null,
    val backfillRequests: List<ScopeBackfillRequest> = emptyList(),
    val items: List<TransferItem> = emptyList(),
    val nextQueueSequence: Long = 1L,
    /** AUDIT-01: the currently-open window's persistent id, or null between
     *  windows (right after the previous one's `flow.round.finished` fired,
     *  before the next discovery admits new candidates). */
    val currentRoundId: String? = null,
    /** AUDIT-01: durable outbox of audit facts awaiting delivery to the
     *  daemon. A dispatcher drains it with [DiscoveryLedgerStore.acknowledgeAuditEvents]
     *  after a durable ack; entries are never mutated, only appended or removed. */
    val auditOutbox: List<AuditOutboxEvent> = emptyList(),
    /**
     * MOB-87: 远端核对进度——上一轮对账核实到的最后一个 `queueSequence`。
     *
     * **这是一个循环游标，不是单调水位线。** 走到账本尾部就回 0，下一轮
     * 从头再来。理由：桌面上的照片随时可能消失（磁盘、误删、库被挪走），
     * 「核实过一次就永远不再看」等于把本卡要修的问题推迟到首轮对账之后。
     *
     * 用游标而不是「过滤掉已 PRESENT 的项」，差别正在这里：后者首轮之后
     * 核对页永久为空，再也不复查。
     */
    val reconcileCursor: Long = 0L,
)

private val TERMINAL_DELIVERY_STATES = setOf(
    DeliveryState.CONFIRMED,
    DeliveryState.FAILED_NEEDS_USER,
    DeliveryState.SKIPPED_SOURCE_MISSING,
    DeliveryState.CANCELLED_BY_SCOPE,
    DeliveryState.CANCELLED_BY_USER_ROUND,
)

/**
 * Persists the ARCH-01 discovery boundary. The single snapshot is the commit
 * unit: a failed action before [beforeCommit] cannot advance the cursor, and a
 * successful replacement makes both the newly admitted items and cursor visible
 * together after restart.
 */
class DiscoveryLedgerStore(
    private val repository: FlowLedgerRepository,
    private val writeGuard: LedgerWriteGuard = UncheckedLedgerWrites,
) {
    /** 兼容既有构造方式（测试与尚未接线的调用点）：默认用 JSON 文件实现。 */
    constructor(dir: File) : this(JsonFileFlowLedgerRepository(dir))

    // MOB-88: 内存里的这一份就是权威状态。单写者模型下不存在「文件里有一份
    // 更新的」这种事，所以读路径不再碰磁盘——顺带干掉了 UI 每 500ms 重读
    // 整份 JSON 的开销，以及「读操作里藏着写」那条锁外写入路径。
    @Volatile
    private var cached: DiscoveryLedgerSnapshot? = null

    private val listeners = java.util.concurrent.CopyOnWriteArrayList<(DiscoveryLedgerSnapshot) -> Unit>()

    fun load(): DiscoveryLedgerSnapshot =
        cached ?: synchronized(this) {
            cached ?: (repository.read() ?: DiscoveryLedgerSnapshot()).also { cached = it }
        }

    /**
     * 每次提交后回调，用于 UI 订阅——取代改造前的轮询。回调在写者线程上
     * 同步触发，实现方必须自己切线程，且不得回头写账本。
     */
    fun onCommit(listener: (DiscoveryLedgerSnapshot) -> Unit) {
        listeners += listener
    }

    /**
     * MOB-53 的一次性迁移：UI-09 加 `completedAt` 之前就 CONFIRMED 的条目
     * 没有完成时间（0 不是「还没完成」，是「我们没记下来」），用当下时钟
     * 盖一次并持久化。
     *
     * MOB-88：改造前这段藏在 `load()` 里，于是**读操作变成了写操作**——UI
     * 每 500ms 轮询都可能触发一次锁外落盘。现在它是启动时跑一次的显式动作。
     */
    fun migrateMissingCompletedAt() {
        val snapshot = load()
        var changed = false
        val backfilled = snapshot.items.map { item ->
            if (item.deliveryState == DeliveryState.CONFIRMED && item.completedAt <= 0L) {
                changed = true
                item.copy(completedAt = System.currentTimeMillis())
            } else {
                item
            }
        }
        if (!changed) return
        persist(snapshot.copy(items = backfilled))
    }

    fun startCancellationRound(id: String) {
        val current = load()
        require(current.cancellationRound == null) { "a cancellation round is already active" }
        persist(current.copy(cancellationRound = CancellationRound(id)))
    }

    /** ARCH-03 consumer transitions use the same durable snapshot boundary. */
    fun update(transform: (DiscoveryLedgerSnapshot) -> DiscoveryLedgerSnapshot) {
        persist(transform(load()))
    }

    /**
     * AUDIT-01: drop acknowledged outbox events. Calling this twice with the
     * same ids (a repeated ack after the daemon confirmed receipt but the
     * phone crashed before recording it locally) is a no-op the second time
     * — idempotent by construction, since a missing id simply matches nothing.
     */
    fun acknowledgeAuditEvents(eventIds: Set<String>) {
        if (eventIds.isEmpty()) return
        update { snapshot -> snapshot.copy(auditOutbox = snapshot.auditOutbox.filterNot { it.eventId in eventIds }) }
    }

    fun commitDiscoveryPage(
        candidates: List<DiscoveryCandidate>,
        nextCursor: DiscoveryCursor,
        discoveryRequested: Boolean? = null,
        beforeCommit: () -> Unit = {},
    ) {
        require(candidates.size <= DISCOVERY_PAGE_SIZE) { "discovery page exceeds $DISCOVERY_PAGE_SIZE items" }
        val current = load()
        val byStableId = current.items.associateBy { it.stableId }.toMutableMap()
        var nextSequence = current.nextQueueSequence
        val state = if (current.cancellationRound == null) {
            DeliveryState.QUEUED
        } else {
            DeliveryState.CANCELLED_BY_USER_ROUND
        }
        val cancellationRoundId = current.cancellationRound?.id
        // AUDIT-01: every ordinary window carries one persistent roundId for
        // its whole lifetime. Admitting into an already-open window reuses
        // it; admitting into a closed/empty ledger opens a fresh one.
        var roundId = current.currentRoundId
        var admittedAny = false

        candidates.forEach { candidate ->
            if (candidate.stableId !in byStableId) {
                if (roundId == null) roundId = UUID.randomUUID().toString()
                admittedAny = true
                byStableId[candidate.stableId] = TransferItem(
                    stableId = candidate.stableId,
                    sourceRef = candidate.sourceRef,
                    sourceVersion = candidate.sourceVersion,
                    bucketId = candidate.bucketId,
                    fileName = candidate.fileName,
                    mediaType = candidate.mediaType,
                    scopeRevision = current.scopeRevision,
                    pairingEpoch = current.pairingEpoch,
                    queueSequence = nextSequence++,
                    deliveryState = state,
                    cancellationRoundId = cancellationRoundId,
                    captureAtMs = candidate.captureAtMs,
                    roundId = roundId,
                )
            }
        }

        val next = current.copy(
            discoveryRequested = discoveryRequested ?: current.discoveryRequested,
            cursor = nextCursor,
            items = byStableId.values.sortedBy { it.queueSequence },
            nextQueueSequence = nextSequence,
            currentRoundId = if (admittedAny) roundId else current.currentRoundId,
        )
        beforeCommit()
        persist(next)
    }

    /**
     * Appends one historical scope-expansion page without moving the live
     * discovery cursor or disturbing the current strict head.
     */
    fun commitScopeBackfill(request: ScopeBackfillRequest, page: ScopeBackfillPage) {
        val current = load()
        val index = current.backfillRequests.indexOf(request)
        require(index >= 0) { "scope backfill request is no longer active" }
        val byStableId = current.items.associateBy { it.stableId }.toMutableMap()
        var nextSequence = current.nextQueueSequence
        val state = if (current.cancellationRound == null) {
            DeliveryState.QUEUED
        } else {
            DeliveryState.CANCELLED_BY_USER_ROUND
        }
        val cancellationRoundId = current.cancellationRound?.id
        var roundId = current.currentRoundId
        var admittedAny = false
        page.candidates.forEach { candidate ->
            if (candidate.stableId !in byStableId) {
                if (roundId == null) roundId = UUID.randomUUID().toString()
                admittedAny = true
                byStableId[candidate.stableId] = TransferItem(
                    stableId = candidate.stableId,
                    sourceRef = candidate.sourceRef,
                    sourceVersion = candidate.sourceVersion,
                    bucketId = candidate.bucketId,
                    fileName = candidate.fileName,
                    mediaType = candidate.mediaType,
                    scopeRevision = request.scopeRevision,
                    pairingEpoch = current.pairingEpoch,
                    queueSequence = nextSequence++,
                    deliveryState = state,
                    cancellationRoundId = cancellationRoundId,
                    captureAtMs = candidate.captureAtMs,
                    roundId = roundId,
                )
            }
        }
        val requests = current.backfillRequests.toMutableList()
        if (page.complete) {
            requests.removeAt(index)
        } else {
            require(page.nextCursor != request.cursor) { "incomplete scope backfill must advance" }
            requests[index] = request.copy(cursor = page.nextCursor)
        }
        persist(
            current.copy(
                backfillRequests = requests,
                items = byStableId.values.sortedBy { it.queueSequence },
                nextQueueSequence = nextSequence,
                currentRoundId = if (admittedAny) roundId else current.currentRoundId,
            ),
        )
    }

    /**
     * AUDIT-01: once every item in the currently-open window reaches a
     * terminal delivery state, close the window with exactly one
     * `flow.round.finished` summary and free `currentRoundId` so the next
     * discovered window gets a fresh persistent id. Runs on every persisted
     * snapshot so it fires exactly once, from whichever call site drove the
     * last item to a terminal state.
     */
    private fun finalizeRoundIfComplete(snapshot: DiscoveryLedgerSnapshot): DiscoveryLedgerSnapshot {
        val roundId = snapshot.currentRoundId ?: return snapshot
        val roundItems = snapshot.items.filter { it.roundId == roundId }
        if (roundItems.isEmpty() || !roundItems.all { it.deliveryState in TERMINAL_DELIVERY_STATES }) {
            return snapshot
        }
        val summary = mapOf(
            "confirmed" to roundItems.count { it.deliveryState == DeliveryState.CONFIRMED }.toString(),
            "failed" to roundItems.count { it.deliveryState == DeliveryState.FAILED_NEEDS_USER }.toString(),
            "cancelled" to roundItems.count {
                it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND || it.deliveryState == DeliveryState.CANCELLED_BY_SCOPE
            }.toString(),
            "skippedSourceMissing" to roundItems.count { it.deliveryState == DeliveryState.SKIPPED_SOURCE_MISSING }.toString(),
        )
        return snapshot.copy(currentRoundId = null)
            .appendAudit(AuditKinds.ROUND_FINISHED, roundId = roundId, payload = summary)
    }

    private fun persist(snapshot: DiscoveryLedgerSnapshot) {
        // MOB-88: 门禁在最内层——不管调用方是谁、走了几层，只要不在写者
        // 线程上就当场抛，而不是静默覆盖别人刚写进去的字段。
        writeGuard.assertAllowed()
        val finalized = finalizeRoundIfComplete(snapshot)
        repository.write(finalized)
        cached = finalized
        listeners.forEach { it(finalized) }
    }

    private companion object {
        const val DISCOVERY_PAGE_SIZE = 500
    }
}
