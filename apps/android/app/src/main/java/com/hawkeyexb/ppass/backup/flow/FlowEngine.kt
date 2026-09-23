// ARCH-13 (#417): 逐张循环。取代 DiscoveryLedger / StrictConsumer / FlowRunner / CancellationRoundController /
// ReconciliationCoordinator / CompletionAndScope 的队列与窗口部分。
//
// 单写者（MOB-88 的思想保留）：所有状态变更都在 [scope] 上执行，而 [scope] 跑在一个单线程
// dispatcher 上（生产见 FlowWriter）。算 hash、读 MediaStore、走网络都 `withContext(io)` 出去，
// 挂起期间写者线程空出来处理别的命令（暂停、取消），所以不会被一张 4GB 视频卡住。
// 「并发」不是靠锁挡住的，是不存在：同一时刻只有一个协程在写 order。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.ApplyStats
import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.DiffAction
import com.hawkeyexb.ppass.backup.order.DiffApplier
import com.hawkeyexb.ppass.backup.order.DiffPlanner
import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.LocalReconciler
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.backup.order.SkipTarget
import com.hawkeyexb.ppass.backup.order.VolumeState
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class FlowEngine(
    private val store: OrderStore,
    private val media: MediaSnapshotSource,
    private val hasher: ContentHasher,
    private val delivery: ItemDelivery,
    private val probe: DesktopProbe,
    private val presence: RemotePresence,
    private val foreground: ForegroundLease,
    private val scheduler: WakeScheduler,
    private val control: FlowControl,
    private val conditions: () -> Conditions,
    private val inScope: (bucketId: Long) -> Boolean,
    /** 当前配对代号；null = 未配对。 */
    private val pairingEpoch: () -> PairingEpoch?,
    /** 单写者 scope。 */
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val log: FlowLogger = FlowLogger { },
    private val clock: () -> Long = System::currentTimeMillis,
    /** 每轮结束后（审计 outbox 冲刷等）。 */
    private val afterCycle: () -> Unit = {},
    /** 桌面宣布了新的配对代号（同一台桌面重新配对）：持久化它。 */
    private val onEpochAdvertised: (String) -> Unit = {},
) {
    private val planner = DiffPlanner(
        hasher = { snapshot -> hasher.hash(snapshot.mediaId) },
        ordersWithHash = store::ordersWithHash,
        inScope = inScope,
    )
    private val applier = DiffApplier(store, { pairingEpoch()?.value.orEmpty() }, clock)
    private val reconciler = LocalReconciler(store, media, planner, applier)

    private val _status = MutableStateFlow(LoopStatus())
    val status: StateFlow<LoopStatus> = _status.asStateFlow()

    /** 每次 order 写入后 +1：UI 投影据此重算计数（取代账本提交回调）。 */
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision.asStateFlow()

    // ---- 以下字段只在写者 scope 上读写 ----
    private var cycleJob: Job? = null
    private val pending = LinkedHashSet<TriggerReason>()
    private var started = false

    private fun bump() {
        _revision.update { it + 1 }
    }

    private fun audit(kind: String, payload: Map<String, String>) =
        AuditRecord(UUID.randomUUID().toString(), kind, null, clock(), payload)

    // ---------------------------------------------------------------- 命令

    /**
     * 进程启动：上一条进程遗留的 TRANSFERRING（那次传输随进程死了）降回 PAUSED，下次按 ① 续传。
     * 只跑一次。
     */
    fun start(): Job = scope.launch {
        if (started) return@launch
        started = true
        store.currentInStates(setOf(OrderState.TRANSFERRING), Int.MAX_VALUE).forEach {
            store.transition(it.id, setOf(OrderState.TRANSFERRING), OrderState.PAUSED)
        }
        bump()
    }

    /**
     * 任何触发的唯一入口。先查暂停（#413：任何触发都先检查暂停，暂停中一律不发）；
     * 循环已在跑就合并（D-02：同一时间只有一个循环），跑完再用合并后的原因补跑一轮。
     */
    fun trigger(reason: TriggerReason): Job = scope.launch { onTrigger(reason) }

    /** 写者上执行。返回 true = 这次触发起了一轮新的循环。 */
    private fun onTrigger(reason: TriggerReason): Boolean {
        if (control.paused()) {
            log.log("trigger $reason ignored: paused by user")
            _status.value = LoopStatus(phase = LoopPhase.IDLE)
            return false
        }
        pending += reason
        if (cycleJob?.isActive == true) {
            log.log("trigger $reason coalesced into the running cycle")
            return false
        }
        cycleJob = scope.launch { drain() }
        return true
    }

    /**
     * worker 用：触发之后，等到这一轮的「检查」阶段结束（已申请到 FGS 开始传，或已判定不用跑 / 要等）。
     * worker 自己的 10 分钟执行上限因此只覆盖检查阶段；传输跑在进程级 scope + 自己的 FGS 下。
     */
    suspend fun triggerAndAwaitChecks(reason: TriggerReason) {
        val before = scope.async { checksDone.value.takeIf { onTrigger(reason) } }.await() ?: return
        checksDone.first { it > before }
    }

    /** 每轮「检查阶段结束」+1（进入 RUNNING 或判定不跑）。 */
    private val checksDone = MutableStateFlow(0L)

    /**
     * C-01：暂停 = 持久化 → 退出循环 → 释放 FGS，不做任何保活。**这条路径不会申请 FGS**（#414）。
     */
    fun pause(): Job = scope.launch {
        control.setPaused(true)
        pending.clear()
        cycleJob?.cancelAndJoin()
        store.appendAudit(audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "pause")))
        _status.value = LoopStatus(phase = LoopPhase.IDLE)
        bump()
        afterCycle()
    }

    /** 只有用户 Continue 能解除暂停。 */
    fun continueFlow(): Job = scope.launch {
        control.setPaused(false)
        store.appendAudit(audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "continue")))
        bump()
        trigger(TriggerReason.USER_CONTINUE).join()
    }

    /**
     * X-01：「取消剩余 N 张」。停掉当前这张（通知桌面丢掉它的部分数据），然后把剩下的照片
     * （含 FAILED，#415 裁决 7）在**一个事务**里逐张写成 SKIPPED_BY_USER。不需要先暂停（#415 裁决 4）。
     * 返回 N（真正写成 SKIPPED_BY_USER 的张数）。
     */
    fun cancelRemaining(): Deferred<Int> = scope.async {
        pending.clear()
        cycleJob?.cancelAndJoin()
        val epoch = pairingEpoch() ?: return@async 0
        // 已经跟桌面打过交道的那几张（续传中 / 暂停中）：请桌面丢掉部分数据。
        store.currentInStates(setOf(OrderState.PAUSED, OrderState.TRANSFERRING), Int.MAX_VALUE)
            .forEach { delivery.discardPartial(it.id, epoch) }
        val targets = withContext(io) { remainingTargets() }
        val result = store.skipByUser(
            targets,
            epoch.value,
            audit = audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "cancel", "skipped" to targets.size.toString())),
        )
        log.log("cancel: ${result.written} photos recorded as SKIPPED_BY_USER (${result.untouched} already decided)")
        _status.value = LoopStatus(phase = LoopPhase.IDLE)
        bump()
        afterCycle()
        result.written
    }

    /** FGS 被系统收走（onTimeout）：记事实、停循环。**不**再调 startForegroundService（#414）。 */
    fun onForegroundLost(reason: FgsBlockReason = FgsBlockReason.BUDGET_EXHAUSTED): Job = scope.launch {
        control.recordFgsBlock(reason)
        log.log("foreground lost ($reason): stopping the loop, no restart until the app is in the foreground")
        cycleJob?.cancelAndJoin()
        _status.value = LoopStatus(phase = LoopPhase.IDLE, waitReason = WaitReason.FGS_BLOCKED)
    }

    /** App 回到前台：清掉 FGS 受阻事实（前台重置额度），跑一次慢路径 + 循环。 */
    fun onAppForeground(): Job = scope.launch {
        control.clearFgsBlock()
        trigger(TriggerReason.APP_FOREGROUND).join()
    }

    /**
     * 网络变化回调：正在跑且条件已不满足（例如仅 Wi‑Fi 却切到了移动网络）→ 停掉循环、释放 FGS、
     * 登记约束唤醒；否则当作一次触发。
     */
    fun onNetworkChanged(): Job = scope.launch {
        val running = cycleJob?.isActive == true
        val reason = waitReasonOf(conditions(), userPresent = false)
        if (running && (reason == WaitReason.WIFI)) {
            log.log("network changed: $reason no longer satisfied, stopping the loop")
            pending.clear()
            cycleJob?.cancelAndJoin()
            scheduler.scheduleWhenConditionsMet(reason)
            _status.value = LoopStatus(phase = LoopPhase.IDLE, waitReason = reason)
            return@launch
        }
        trigger(TriggerReason.NETWORK_CHANGE).join()
    }

    fun acknowledgeAudit(eventIds: Set<String>): Job = scope.launch {
        store.acknowledgeAudit(eventIds)
    }

    fun acknowledgeMissingSource(): Job = scope.launch {
        control.setMissingSourceAckAt(clock())
        bump()
    }

    /** 测试与关停用：等当前这一轮跑完。 */
    suspend fun awaitIdle() {
        scope.async { cycleJob }.await()?.join()
    }

    // ---------------------------------------------------------------- 一轮

    private suspend fun drain() {
        try {
            while (pending.isNotEmpty()) {
                val reasons = pending.toSet()
                pending.clear()
                try {
                    runCycle(reasons)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    // 一轮失败（例如存储写入抛错）不能让引擎死掉——下一次触发照常来。但绝不静默：留痕。
                    log.log("cycle $reasons failed: ${failure.javaClass.simpleName}: ${failure.message}")
                    settle(null)
                }
            }
        } finally {
            if (_status.value.phase != LoopPhase.IDLE) _status.update { it.copy(phase = LoopPhase.IDLE, current = null) }
            checksDone.update { it + 1 }
            withContext(NonCancellable) { afterCycle() }
        }
    }

    private fun settle(wait: WaitReason?) {
        _status.value = LoopStatus(phase = LoopPhase.IDLE, waitReason = wait)
        checksDone.update { it + 1 }
    }

    private suspend fun runCycle(reasons: Set<TriggerReason>) {
        val userPresent = reasons.any { it.userPresent }
        _status.value = LoopStatus(phase = LoopPhase.CHECKING)
        if (control.paused()) return settle(null)
        val epoch = pairingEpoch() ?: return settle(WaitReason.NOT_PAIRED)

        val slow = reasons.any { it.slowPath } || withContext(io) { mediaStoreVersionChanged() }
        if (slow) runLocalSlowPath()

        // ---- worker 里的检查，此时不持有 FGS ----
        waitReasonOf(conditions(), userPresent)?.let { reason ->
            log.log("cycle $reasons: waiting for $reason (no foreground service requested)")
            if (reason == WaitReason.WIFI || reason == WaitReason.BATTERY) scheduler.scheduleWhenConditionsMet(reason)
            return settle(reason)
        }
        var first = pickNext()
        if (first == null && !slow) return settle(null)
        when (val reach = withContext(io) { probe.probe() }) {
            ProbeResult.Unreachable -> {
                if (first == null) return settle(null)
                log.log("cycle $reasons: desktop unreachable, scheduling probes; no foreground service, no attempt counted")
                scheduler.scheduleUnreachableProbes()
                return settle(WaitReason.DESKTOP_UNREACHABLE)
            }
            ProbeResult.PairingLost -> return settle(WaitReason.NOT_PAIRED)
            is ProbeResult.Reachable -> {
                scheduler.cancelUnreachableProbes()
                reach.advertisedEpoch?.takeIf { it.isNotBlank() && it != epoch.value }?.let(onEpochAdvertised)
            }
        }
        if (slow) {
            runRemotePresence()
            if (first == null) first = pickNext()
        }
        if (first == null) return settle(null)

        // ---- 申请 FGS + wakelock：整个循环只申请这一次（C-06） ----
        if (!foreground.acquire()) {
            control.recordFgsBlock(FgsBlockReason.START_REFUSED)
            log.log("foreground service refused: recorded, not retrying until the app is in the foreground")
            return settle(WaitReason.FGS_BLOCKED)
        }
        _status.value = LoopStatus(phase = LoopPhase.RUNNING)
        checksDone.update { it + 1 }
        var exit: WaitReason? = null
        try {
            exit = loop(first, userPresent)
        } finally {
            withContext(NonCancellable) {
                // 被暂停 / 取消 / 超时打断时，在飞的那张退回 PAUSED（可续传，不计次数）。
                store.currentInStates(setOf(OrderState.TRANSFERRING), Int.MAX_VALUE).forEach {
                    store.transition(it.id, setOf(OrderState.TRANSFERRING), OrderState.PAUSED)
                }
                foreground.release()
                bump()
                settle(exit)
            }
        }
    }

    /** 逐张循环本体。返回退出原因（null = 取不到下一张，正常结束）。 */
    private suspend fun loop(first: WorkItem, userPresent: Boolean): WaitReason? {
        var item: WorkItem? = first
        val seen = HashSet<Long>()
        while (item != null) {
            // C-07：每张开始前重检条件，并确认 FGS 仍然有效。
            if (control.paused()) return null
            waitReasonOf(conditions(), userPresent)?.let { reason ->
                if (reason == WaitReason.WIFI || reason == WaitReason.BATTERY) scheduler.scheduleWhenConditionsMet(reason)
                return reason
            }
            if (!foreground.isHeld()) return WaitReason.FGS_BLOCKED
            val epoch = pairingEpoch() ?: return WaitReason.NOT_PAIRED
            if (item is WorkItem.Existing && !seen.add(item.order.id)) {
                log.log("order ${item.order.id} picked twice in one cycle; stopping to avoid a spin")
                return null
            }
            when (val step = process(item, epoch)) {
                StepResult.Next -> Unit
                is StepResult.Exit -> return step.reason
            }
            foreground.renew()
            item = pickNext()
        }
        return null
    }

    private sealed interface WorkItem {
        data class Existing(val order: Order) : WorkItem
        data class Fresh(val snapshot: MediaSnapshot, val contentHash: String) : WorkItem
    }

    private sealed interface StepResult {
        data object Next : StepResult
        data class Exit(val reason: WaitReason) : StepResult
    }

    private suspend fun process(item: WorkItem, epoch: PairingEpoch): StepResult {
        val (order, details) = when (item) {
            is WorkItem.Existing -> prepareExisting(item.order, epoch) ?: return StepResult.Next
            is WorkItem.Fresh -> {
                val details = withContext(io) { media.lookup(item.snapshot.mediaId) }
                if (details == null) {
                    store.advanceGeneration(GenerationAdvance(item.snapshot.volumeName, item.snapshot.generation))
                    return StepResult.Next
                }
                // hash → 建 order → 传输（#413）。G 在结局落库时一起推进（#415 裁决 8）。
                val row = store.insert(
                    NewOrder(item.snapshot.mediaId, item.snapshot.sourceVersion, item.snapshot.bucketId, item.contentHash, OrderState.TRANSFERRING, epoch.value),
                )
                bump()
                row to details
            }
        }
        val hash = checkNotNull(order.contentHash)
        val request = DeliveryRequest(order.id, epoch, hash, details)
        _status.value = LoopStatus(LoopPhase.RUNNING, CurrentItem(order.id, details.fileName, 0L, details.sizeBytes))
        foreground.update(_status.value)
        val advance = GenerationAdvance(details.snapshot.volumeName, details.snapshot.generation)

        var outcome = deliverOnce(request)
        if (outcome is DeliveryOutcome.ItemFailure) {
            // C-09：单张失败立即重试 1 次。
            log.log("order ${order.id}: item failure (${outcome.reason}); retrying once")
            outcome = deliverOnce(request)
        }
        return when (outcome) {
            is DeliveryOutcome.Confirmed -> {
                val receipt = outcome.receipt
                val valid = receipt.queueSequence == order.id &&
                    receipt.pairingEpoch == epoch &&
                    (receipt.contentHash == null || receipt.contentHash == hash)
                if (!valid) {
                    log.log("order ${order.id}: receipt does not match the request; treating as item failure")
                    fail(order.id, advance, "receipt_mismatch")
                } else {
                    // E-01 / O-07：CONFIRMED、hash 映射（行本身）、G 推进、确认审计——同一次写入。
                    store.transition(
                        order.id,
                        setOf(OrderState.TRANSFERRING),
                        OrderState.CONFIRMED,
                        advance = advance,
                        audit = audit(
                            AuditKinds.ITEM_CONFIRMED,
                            mapOf(
                                "queueSequence" to order.id.toString(),
                                "sourceVersion" to order.sourceVersion,
                                "contentHash" to hash,
                                "receiptRef" to receipt.receiptId,
                            ),
                        ),
                    )
                }
                bump()
                StepResult.Next
            }
            DeliveryOutcome.SourceMissing -> {
                store.transition(
                    order.id,
                    setOf(OrderState.TRANSFERRING),
                    OrderState.SKIPPED_SOURCE_MISSING,
                    advance = advance,
                    audit = audit(AuditKinds.ITEM_SOURCE_MISSING, mapOf("queueSequence" to order.id.toString())),
                )
                bump()
                StepResult.Next
            }
            is DeliveryOutcome.ItemFailure -> {
                fail(order.id, advance, outcome.reason)
                StepResult.Next
            }
            is DeliveryOutcome.PathFailure -> {
                // C-05 / C-10：路径失败——order 保持可续传，不计单张次数，退出循环、登记探测。
                log.log("order ${order.id}: path failure (${outcome.reason}); leaving it resumable")
                store.transition(order.id, setOf(OrderState.TRANSFERRING), OrderState.PAUSED)
                bump()
                scheduler.scheduleUnreachableProbes()
                StepResult.Exit(WaitReason.DESKTOP_UNREACHABLE)
            }
            is DeliveryOutcome.PeerFailure -> {
                // #415 裁决 3：对端失败——退出循环，不计次数，等下一次唤醒。
                log.log("order ${order.id}: desktop refused to store it (${outcome.code}); waiting for the next wake")
                store.transition(order.id, setOf(OrderState.TRANSFERRING), OrderState.PAUSED)
                bump()
                StepResult.Exit(WaitReason.PEER_REFUSED)
            }
            DeliveryOutcome.PairingLost -> {
                store.transition(order.id, setOf(OrderState.TRANSFERRING), OrderState.PAUSED)
                bump()
                StepResult.Exit(WaitReason.NOT_PAIRED)
            }
        }
    }

    private suspend fun deliverOnce(request: DeliveryRequest): DeliveryOutcome =
        try {
            withContext(io) {
                delivery.deliver(request) { bytes ->
                    _status.update { s -> s.current?.let { s.copy(current = it.copy(bytesSent = bytes)) } ?: s }
                    foreground.renew()
                    foreground.update(_status.value)
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            // 端口没分类的异常：保守地当作这一张的问题（计次数、有上限），不当路径失败（那会无限续）。
            DeliveryOutcome.ItemFailure("unclassified: ${failure.javaClass.simpleName}")
        }

    private fun fail(orderId: Long, advance: GenerationAdvance, reason: String) {
        // 失败通知（FailureNotifier）先不发：失败要先按 路径 / 单张 / 对端 分类（#410），而且慢路径兜底会
        // 自动再试一次 FAILED——现在就推通知，大多数是会自愈的问题（#413「UI 与通知」）。
        store.transition(
            orderId,
            setOf(OrderState.TRANSFERRING),
            OrderState.FAILED,
            countAttempt = true,
            advance = advance,
            audit = audit(AuditKinds.ITEM_ATTENTION, mapOf("reason" to reason, "queueSequence" to orderId.toString())),
        )
        bump()
    }

    /**
     * ① / ② 取到的已有 order：开始前按新范围、原图、版本重检（X-06 / X-07），通过后置为 TRANSFERRING。
     * 返回 null = 这张已经就地收尾，取下一张。
     */
    private suspend fun prepareExisting(order: Order, epoch: PairingEpoch): Pair<Order, MediaDetails>? {
        val details = withContext(io) { media.lookup(order.mediaId) }
        if (details == null || details.snapshot.sourceVersion != order.sourceVersion) {
            // 原图没了；或原图已被编辑成新版本——这一行描述的那个版本已不存在，新版本由快/慢路径另起一行。
            store.transition(
                order.id,
                OPEN,
                OrderState.SKIPPED_SOURCE_MISSING,
                audit = audit(AuditKinds.ITEM_SOURCE_MISSING, mapOf("queueSequence" to order.id.toString())),
            )
            bump()
            return null
        }
        if (!inScope(details.snapshot.bucketId)) {
            // #415 裁决 5：改范围当场不处理，到这里（下一张开始之前）才按新范围检查。
            if (order.state == OrderState.PAUSED) delivery.discardPartial(order.id, epoch)
            store.transition(order.id, OPEN, OrderState.CANCELLED_BY_SCOPE)
            bump()
            return null
        }
        val hash = order.contentHash ?: try {
            withContext(io) { hasher.hash(order.mediaId) }.also { store.setContentHash(order.id, it) }
        } catch (_: SourceMissingException) {
            store.transition(order.id, OPEN, OrderState.SKIPPED_SOURCE_MISSING)
            bump()
            return null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            store.transition(order.id, OPEN, OrderState.FAILED, countAttempt = true)
            bump()
            return null
        }
        if (!store.transition(order.id, setOf(OrderState.PAUSED, OrderState.QUEUED, OrderState.TRANSFERRING), OrderState.TRANSFERRING)) return null
        return store.get(order.id)!!.copy(contentHash = hash) to details
    }

    /** 取件顺序：① 未完成 → ② 慢路径标记的 QUEUED → ③ 快路径下一张。 */
    private suspend fun pickNext(): WorkItem? {
        while (true) {
            store.currentInStates(setOf(OrderState.TRANSFERRING, OrderState.PAUSED), 1).firstOrNull()
                ?.let { return WorkItem.Existing(it) }
            store.currentInStates(setOf(OrderState.QUEUED), 1).firstOrNull()
                ?.let { return WorkItem.Existing(it) }
            when (val fast = fastPathStep()) {
                FastStep.Exhausted -> return null
                FastStep.Recheck -> continue
                is FastStep.Found -> return fast.item
            }
        }
    }

    private sealed interface FastStep {
        data object Exhausted : FastStep
        data object Recheck : FastStep
        data class Found(val item: WorkItem) : FastStep
    }

    /**
     * 快路径：每个卷按 `generation > G_卷` 取（#416 裁决 7），按 generation 升序（D-01：新照片不插队）。
     * 不需要动作的照片直接推进 G；需要改 order 的（换映射、重新准入）落库后回到 ① ② 重新取。
     */
    private suspend fun fastPathStep(): FastStep {
        for (volume in withContext(io) { media.volumeNames() }) {
            while (true) {
                val g = store.volumeState(volume)?.fastPathGeneration ?: 0L
                val batch = withContext(io) { media.readChangedSince(volume, g) { it.take(FAST_BATCH).toList() } }
                if (batch.isEmpty()) break
                for (snapshot in batch) {
                    val current = store.currentForMedia(snapshot.mediaId)
                    val action = withContext(io) { planner.classify(snapshot, current) }
                    val advance = GenerationAdvance(volume, snapshot.generation)
                    when (action) {
                        is DiffAction.Upload -> return FastStep.Found(WorkItem.Fresh(snapshot.copy(volumeName = volume), action.contentHash))
                        null, is DiffAction.Suppressed -> store.advanceGeneration(advance)
                        else -> {
                            applier.applyPresent(action)
                            store.advanceGeneration(advance)
                            bump()
                            return FastStep.Recheck
                        }
                    }
                }
            }
        }
        return FastStep.Exhausted
    }

    // ---------------------------------------------------------------- 慢路径

    private fun mediaStoreVersionChanged(): Boolean {
        val versions = media.volumeVersions()
        return versions.any { (volume, version) -> store.volumeState(volume)?.mediaStoreVersion != version }
    }

    /** 慢路径第 1 步（手机完整性检查，两遍）与第 3 步（FAILED 重试一次）。 */
    private suspend fun runLocalSlowPath() {
        val volumes = withContext(io) { media.volumeNames() }
        val freshStart = store.countCurrentByState(null).isEmpty() &&
            volumes.all { (store.volumeState(it)?.fastPathGeneration ?: 0L) == 0L }
        if (freshStart) {
            // order 表是空的且 G 全为 0（首次安装、或换桌面刚清空）：全量对账只会在不持有 FGS、
            // 什么都不落库的情况下把整个相册算一遍 hash——进程中途被杀就永远从头来、永远传不出第一张。
            // G 全为 0 时快路径本来就会按 generation 逐张走过每一张（在 FGS 下边算边传），
            // 所以只记下 getVersion，把工作交给快路径。
            withContext(io) { media.volumeVersions() }.forEach { (volume, version) ->
                val prev = store.volumeState(volume)
                store.saveVolumeState(VolumeState(volume, prev?.fastPathGeneration ?: 0L, version))
            }
            log.log("slow path: fresh start (empty order table, G = 0), deferring to the fast path")
            bump()
            return
        }
        val stats = ApplyStats()
        val present = withContext(io) { reconciler.collectPresent() }
        reconciler.applyPresent(present, stats)
        // 第二遍必须在第一遍落库之后（DiffPlanner 的 KDoc）。
        val gone = withContext(io) { reconciler.collectGone() }
        reconciler.applyGone(gone, stats)
        // O-09：每次慢路径，FAILED 只重试一次——翻成 QUEUED，循环按取件顺序 ② 传；再失败就又是 FAILED。
        val failed = store.currentInStates(setOf(OrderState.FAILED), Int.MAX_VALUE)
        failed.forEach { store.transition(it.id, setOf(OrderState.FAILED), OrderState.QUEUED) }
        // D-05：记下这次全量对账看到的 getVersion。
        withContext(io) { media.volumeVersions() }.forEach { (volume, version) ->
            val prev = store.volumeState(volume)
            store.saveVolumeState(VolumeState(volume, prev?.fastPathGeneration ?: 0L, version))
        }
        log.log("slow path: $stats, failed retried=${failed.size}")
        bump()
    }

    /**
     * 慢路径第 2 步：分页问桌面「已确认的这些还在吗」（O-08）。缺的且原图还在 → 新增一行 QUEUED 自动补传；
     * 原图也没了 → 只记审计 `unrecoverable`（#415 裁决 2）。用户明确决定过的（SKIPPED_BY_USER）不在
     * CONFIRMED 里，天然不会被补。
     */
    private suspend fun runRemotePresence() {
        var after = 0L
        var requeued = 0
        while (true) {
            val page = store.confirmedWithHashAfter(after, REMOTE_PRESENCE_PAGE_SIZE)
            if (page.isEmpty()) break
            val missing = try {
                withContext(io) { presence.missing(page.mapNotNull { it.contentHash }.distinct()) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (unreachable: Exception) {
                log.log("presence probe failed (${unreachable.javaClass.simpleName}); retrying next slow path")
                break
            }
            for (order in page) {
                val hash = order.contentHash ?: continue
                if (hash !in missing) continue
                if (order.sourceMissing) {
                    store.appendAudit(
                        audit(AuditKinds.RECONCILIATION_RESOLVED, mapOf("disposition" to "UNRECOVERABLE", "contentHash" to hash)),
                    )
                } else {
                    store.insert(
                        NewOrder(order.mediaId, order.sourceVersion, order.bucketId, hash, OrderState.QUEUED, order.pairingEpoch),
                        audit = audit(AuditKinds.RECONCILIATION_RESOLVED, mapOf("disposition" to "REUPLOAD", "contentHash" to hash)),
                    )
                    requeued++
                }
            }
            after = page.last().id
        }
        if (requeued > 0) log.log("presence: desktop is missing $requeued confirmed photos; re-uploading")
        bump()
    }

    // ---------------------------------------------------------------- 取消

    /**
     * 「剩下的」= 范围内、还没有 order 的照片 + 所有还没结局的当前行（含 FAILED）。
     * 两条流都按 media_id 升序，归并一次。
     */
    private fun remainingTargets(): List<SkipTarget> {
        val out = ArrayList<SkipTarget>()
        media.readAll { snapshots ->
            store.readCurrentOrders { orders ->
                val s = snapshots.iterator()
                val o = orders.iterator()
                var snap = if (s.hasNext()) s.next() else null
                var order = if (o.hasNext()) o.next() else null
                while (snap != null || order != null) {
                    when {
                        order == null || (snap != null && snap.mediaId < order.mediaId) -> {
                            if (inScope(snap!!.bucketId)) out += SkipTarget(snap.mediaId, snap.sourceVersion, snap.bucketId)
                            snap = if (s.hasNext()) s.next() else null
                        }
                        snap == null || order.mediaId < snap.mediaId -> {
                            if (order.state.isOpen) out += SkipTarget(order.mediaId, order.sourceVersion, order.bucketId, order.contentHash)
                            order = if (o.hasNext()) o.next() else null
                        }
                        else -> {
                            if (order.state.isOpen) out += SkipTarget(order.mediaId, order.sourceVersion, order.bucketId, order.contentHash)
                            snap = if (s.hasNext()) s.next() else null
                            order = if (o.hasNext()) o.next() else null
                        }
                    }
                }
            }
        }
        return out
    }

    companion object {
        private const val FAST_BATCH = 32
        private val OPEN = OrderState.entries.filter { it.isOpen }.toSet()
    }
}
