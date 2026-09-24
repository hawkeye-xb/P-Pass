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
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
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
    /** 单调时钟（ms），只给刷新节流用；[clock] 是墙钟（审计时间戳）。 */
    private val monotonicClock: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val planner = DiffPlanner(
        hasher = { snapshot -> hasher.hash(snapshot.mediaId) },
        ordersWithHash = store::ordersWithHash,
        inScope = inScope,
    )
    private val applier = DiffApplier(store, { pairingEpoch()?.value.orEmpty() }, clock)
    private val reconciler = LocalReconciler(store, media, planner, applier)

    // 写 `_status` 就是写原始运行态；要不要刷新通知 / 首页由 [LoopStatusCell] 按「值变了 + 节流」决定。
    private val _status = LoopStatusCell(scope, publish = { foreground.update(it) }, now = monotonicClock)

    /** 原始运行态：每次写入都是最新值（引擎判断、测试断言用）。 */
    val status: StateFlow<LoopStatus> = _status.raw

    /** 对外展示的运行态：值变了才发，字节进度每秒最多一次。首页英雄区与 FGS 通知都读它。 */
    val display: StateFlow<LoopStatus> = _status.display

    /** 视图里除运行态之外的事实（暂停标志、等待原因、待办、本轮已完成、桌面健康）。 */
    private val facts = MutableStateFlow(
        ViewFacts(paused = control.paused(), waitReason = control.waitReason()),
    )

    /**
     * #413 契约 §3：UI 与 FGS 通知读的唯一视图。暂停压过一切；在传是 RUNNING；有等待原因是 WAITING；否则 IDLE。
     */
    val view: StateFlow<EngineView> = combine(_status.display, facts) { status, f -> engineViewOf(status, f) }
        .stateIn(scope, SharingStarted.Eagerly, engineViewOf(LoopStatus(), facts.value))

    /** 每次 order 写入后 +1：UI 投影据此重算计数（取代账本提交回调）。 */
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision.asStateFlow()

    // ---- 以下字段只在写者 scope 上读写 ----
    private var cycleJob: Job? = null
    private val pending = LinkedHashSet<TriggerReason>()
    private var started = false

    private fun msSince(startedNanos: Long): Long = (System.nanoTime() - startedNanos) / 1_000_000

    private fun bump() {
        _revision.update { it + 1 }
    }

    /** 等待原因：写运行态（通知 / 旧投影读它）、持久化（进程重启后还在）、进视图。 */
    private fun setWait(reason: WaitReason?) {
        control.setWaitReason(reason)
        facts.update { it.copy(waitReason = reason, paused = control.paused()) }
    }

    private fun setPausedFlag(paused: Boolean) {
        control.setPaused(paused)
        facts.update { it.copy(paused = paused) }
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

    /** 全局状态（写者上读）。 */
    private fun globalState(): GlobalState = view.value.state.let { shown ->
        when {
            control.paused() -> GlobalState.PAUSED
            cycleJob?.isActive == true && _status.value.phase == LoopPhase.RUNNING -> GlobalState.RUNNING
            else -> shown.takeIf { it != GlobalState.RUNNING && it != GlobalState.PAUSED }
                ?: if (control.waitReason() != null) GlobalState.WAITING else GlobalState.IDLE
        }
    }

    /**
     * C-01 / 契约 §3：暂停只在「备份中」有效。写暂停标志 → 退出循环（传输端口在取消时同步发 `flow.suspend`）
     * → 释放 FGS。**这条路径不会申请 FGS**（#414）。返回是否真的暂停了。
     */
    fun pause(): Deferred<Boolean> = scope.async {
        if (globalState() != GlobalState.RUNNING) {
            log.log("pause ignored: not running (${globalState()})")
            return@async false
        }
        setPausedFlag(true)
        pending.clear()
        cycleJob?.cancelAndJoin()
        store.appendAudit(audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "pause")))
        _status.value = LoopStatus(phase = LoopPhase.IDLE)
        bump()
        afterCycle()
        true
    }

    /** 契约 §3：继续只在「已暂停」有效；回到入口（续传 + 对账：暂停期间只改了意图，待办现算）。 */
    fun resume(): Deferred<Boolean> = scope.async {
        if (!control.paused()) {
            log.log("resume ignored: not paused")
            return@async false
        }
        setPausedFlag(false)
        setWait(null)
        store.appendAudit(audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "continue")))
        bump()
        onTrigger(TriggerReason.USER_CONTINUE)
        true
    }

    /** 旧入口（UI 还在用）：等价于 [resume]。 */
    fun continueFlow(): Job = scope.launch { resume().await() }

    /**
     * 「取消剩余 N 张」弹窗那一刻的边界 + 张数（契约 §3）。只读，不经过写者 scope，传输进行中也不会被卡住。
     * 确认时交给 [cancelRemaining]：写下的正是这份边界里的照片，弹窗之后新拍的不在里面。
     */
    suspend fun remainingSnapshot(): RemainingSnapshot = withContext(io) {
        val targets = remainingTargets()
        RemainingSnapshot(targets.size, clock(), targets)
    }

    /**
     * X-01 / 契约 §3：「取消剩余 N 张」，只在「已暂停」与「等待中」有效。一个事务把 [snapshot] 里的照片
     * 写成 SKIPPED_BY_USER，已经跟桌面打过交道的请桌面丢掉半截（`cancel_tuple`），清除暂停标志 → 空闲。
     * 返回真正写下的张数；不在允许的状态时返回 null。
     */
    fun cancelRemaining(snapshot: RemainingSnapshot): Deferred<Int?> = scope.async {
        val state = globalState()
        if (state != GlobalState.PAUSED && state != GlobalState.WAITING) {
            log.log("cancel ignored: state is $state")
            return@async null
        }
        pending.clear()
        cycleJob?.cancelAndJoin()
        val epoch = pairingEpoch() ?: return@async 0
        store.currentInStates(setOf(OrderState.PAUSED, OrderState.TRANSFERRING), Int.MAX_VALUE)
            .forEach { delivery.discardPartial(it.id, epoch) }
        val result = store.skipByUser(
            snapshot.targets,
            epoch.value,
            audit = audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "cancel", "skipped" to snapshot.count.toString())),
        )
        log.log("cancel: ${result.written} photos recorded as SKIPPED_BY_USER (${result.untouched} already decided)")
        setPausedFlag(false)
        setWait(null)
        _status.value = LoopStatus(phase = LoopPhase.IDLE)
        bump()
        afterCycle()
        result.written
    }

    /** 旧入口（UI 还在用）：当场拍一份边界再取消。新代码用 [remainingSnapshot] + [cancelRemaining]。 */
    fun cancelRemaining(): Deferred<Int> = scope.async {
        val snapshot = remainingSnapshot()
        if (globalState() == GlobalState.RUNNING) {
            // 旧 UI 允许在跑的时候取消：先按暂停的路径停下（发 flow.suspend），再按契约取消。
            setPausedFlag(true)
            pending.clear()
            cycleJob?.cancelAndJoin()
            _status.value = LoopStatus(phase = LoopPhase.IDLE)
        }
        if (globalState() == GlobalState.IDLE) setPausedFlag(true)
        cancelRemaining(snapshot).await() ?: 0
    }

    /**
     * #418「已跳过的照片 · 点击恢复」：一个事务删掉所有当前行为 SKIPPED_BY_USER 的 order（审计同事务），
     * 然后触发一次慢路径——这些照片没有 order 了，慢路径第一遍把它们重新规划（内容桌面已有的只记映射，
     * 其余成为 QUEUED 进取件顺序 ②）。暂停中只删不传：触发被暂停挡住，之后的下一次慢路径（回到前台、定时兜底）再接上。
     * 返回恢复了几张。
     */
    fun restoreSkipped(): Deferred<Int> = scope.async {
        val count = store.countCurrentByState(null)[OrderState.SKIPPED_BY_USER] ?: 0L
        val restored = store.restoreSkippedByUser(
            audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "restore", "restored" to count.toString())),
        )
        log.log("restore: $restored SKIPPED_BY_USER rows removed; the slow path will plan them again")
        bump()
        // 暂停期间只改意图：不叫醒循环，继续之后对账自然接上。
        if (restored > 0 && !control.paused()) onTrigger(TriggerReason.RESTORE_SKIPPED)
        restored
    }

    /**
     * #418：「取消剩余 N 张」的 N，也是英雄区的「待备份 K」。与 [cancelRemaining] 写 SKIPPED_BY_USER 的
     * 是**同一个函数**（[remainingTargets]），所以确认框里的 N 就是确认后会写下的张数（除非这期间又有
     * 照片确认或新拍）。只读，不经过写者 scope，传输进行中也不会被卡住。
     */
    suspend fun countRemaining(): Int = remainingSnapshot().count

    /** FGS 被系统收走（onTimeout）：记原因、停循环（端口发 flow.suspend）、等待中。下一次触发照常再申请（#413）。 */
    fun onForegroundLost(reason: FgsBlockReason = FgsBlockReason.BUDGET_EXHAUSTED): Job = scope.launch {
        control.recordFgsBlock(reason)
        log.log("foreground lost ($reason): stopping the loop; the next trigger may request it again")
        stopCycle(WaitReason.FGS_BLOCKED)
    }

    /** App 回到前台：一次触发（含对账）。 */
    fun onAppForeground(): Job = scope.launch {
        onTrigger(TriggerReason.APP_FOREGROUND)
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
            stopCycle(reason)
            scheduler.scheduleWhenConditionsMet(reason)
            return@launch
        }
        onTrigger(TriggerReason.NETWORK_CHANGE)
    }

    /**
     * #413：onLost（手机此刻没有任何可用网络）→ 在飞的这张立即判路径失败：停循环（端口尽力发 flow.suspend），
     * order 保持可续传，等待中（桌面不可达）+ 3 次间隔 10 分钟的探测；网络回来时网络回调就是下一次触发。
     */
    fun onNetworkLost(): Job = scope.launch {
        if (cycleJob?.isActive != true) return@launch
        log.log("network lost: path failure for the in-flight item; waiting for the network to come back")
        stopCycle(WaitReason.DESKTOP_UNREACHABLE)
        scheduler.scheduleUnreachableProbes()
    }

    /** 写者上执行：停掉这一轮，进「等待中」。 */
    private suspend fun stopCycle(reason: WaitReason) {
        pending.clear()
        cycleJob?.cancelAndJoin()
        _status.value = LoopStatus(phase = LoopPhase.IDLE, waitReason = reason)
        setWait(reason)
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
        setWait(wait)
        checksDone.update { it + 1 }
    }

    private suspend fun runCycle(reasons: Set<TriggerReason>) {
        val userPresent = reasons.any { it.userPresent }
        _status.value = LoopStatus(phase = LoopPhase.CHECKING)
        if (control.paused()) return settle(null)
        val epoch = pairingEpoch() ?: return settle(WaitReason.NOT_PAIRED)

        // DIAG-A：检查阶段每一步各打一条耗时——首次配对后曾空等 32 秒、一条日志都没有。
        val cycleStarted = System.nanoTime()
        val slow = reasons.any { it.reconcile } || withContext(io) { mediaStoreVersionChanged() }
        if (slow) {
            val t = System.nanoTime()
            runLocalSlowPath()
            log.log("cycle $reasons: check local_slow_path took ${msSince(t)}ms")
        }

        // ---- worker 里的检查，此时不持有 FGS ----
        waitReasonOf(conditions(), userPresent)?.let { reason ->
            log.log("cycle $reasons: waiting for $reason (no foreground service requested)")
            if (reason == WaitReason.WIFI || reason == WaitReason.BATTERY) scheduler.scheduleWhenConditionsMet(reason)
            return settle(reason)
        }
        val pickStarted = System.nanoTime()
        var first = pickNext()
        // pickNext 走快路径时会给下一张算 hash（大视频可能很久），它排在探测之前。
        log.log("cycle $reasons: check pick_next took ${msSince(pickStarted)}ms found=${first != null}")
        if (first == null && !slow) return settle(null)
        val probeStarted = System.nanoTime()
        val reach = withContext(io) { probe.probe() }
        log.log("cycle $reasons: check probe took ${msSince(probeStarted)}ms result=${reach.javaClass.simpleName} sinceCycleStartMs=${msSince(cycleStarted)}")
        when (reach) {
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
                facts.update { it.copy(desktopHealth = reach.health) }
                // 契约 §7：桌面不健康 → 不申请 FGS，等待中（具体原因）。
                waitReasonOf(reach.health)?.let { unhealthy ->
                    log.log("cycle $reasons: desktop unhealthy (${reach.health}); waiting for $unhealthy")
                    return settle(unhealthy)
                }
            }
        }
        if (slow) {
            val t = System.nanoTime()
            runRemotePresence()
            log.log("cycle $reasons: check remote_presence took ${msSince(t)}ms")
            if (first == null) first = pickNext()
        }
        if (first == null) return settle(null)

        // ---- 申请 FGS + wakelock：整个循环只申请这一次（C-06） ----
        if (!foreground.acquire()) {
            control.recordFgsBlock(FgsBlockReason.START_REFUSED)
            log.log("foreground service refused: waiting; the next trigger requests it again")
            return settle(WaitReason.FGS_BLOCKED)
        }
        _status.value = LoopStatus(phase = LoopPhase.RUNNING)
        setWait(null)
        checksDone.update { it + 1 }
        var exit: WaitReason? = null
        try {
            // 一轮一条推送订阅（契约 §5），随 FGS 一起释放。
            exit = delivery.session { loop(first, userPresent) }
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
                log.log("order ${order.id}: desktop cannot store it (${outcome.kind}/${outcome.code}); waiting for the next wake")
                store.transition(order.id, setOf(OrderState.TRANSFERRING), OrderState.PAUSED)
                bump()
                StepResult.Exit(waitReasonOf(outcome.kind))
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
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            // 端口没分类的异常：保守地当作这一张的问题（计次数、有上限），不当路径失败（那会无限续）。
            DeliveryOutcome.ItemFailure("unclassified: ${failure.javaClass.simpleName}")
        }

    private fun fail(orderId: Long, advance: GenerationAdvance, reason: String) {
        // #418：这里是「一张照片记为 FAILED」的唯一调用点，失败通知（FailureNotifier / SystemFailureNotifier，
        // 代码保留）**故意不在这里调用**：
        //  1. 失败要先按 路径 / 单张 / 对端 分类（#410），分类没落地之前，推给用户的「备份失败」多半是误报；
        //  2. 慢路径兜底会自动再试一次 FAILED——现在就推通知，大多数是会自愈的问题。
        // 结构测试 ARCH14UiWiringTest.the_failure_notification_is_kept_but_never_posted 锁住「main 里没有 postFailure 调用点」。
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

/** [FlowEngine.view] 里运行态之外的事实。 */
internal data class ViewFacts(
    val paused: Boolean = false,
    val waitReason: WaitReason? = null,
    val pending: Int = 0,
    val doneThisRound: Int = 0,
    val desktopHealth: DesktopHealth? = null,
)

internal fun engineViewOf(status: LoopStatus, facts: ViewFacts): EngineView {
    val state = when {
        facts.paused -> GlobalState.PAUSED
        status.running -> GlobalState.RUNNING
        facts.waitReason != null -> GlobalState.WAITING
        else -> GlobalState.IDLE
    }
    return EngineView(
        state = state,
        waitReason = facts.waitReason.takeIf { state == GlobalState.WAITING },
        pending = facts.pending,
        doneThisRound = facts.doneThisRound,
        current = status.current.takeIf { state == GlobalState.RUNNING },
        desktopHealth = facts.desktopHealth,
    )
}
