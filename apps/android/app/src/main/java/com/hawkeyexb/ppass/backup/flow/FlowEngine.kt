// ARCH-13 (#417) → #413: 逐张循环（依赖倒置：循环不认识「哪类照片」，只认识「取件来源」）。
//
// 入口（不持有 FGS、不读文件、不做 presence 网络请求）：
//   暂停？→ 游标就位（G 缺失 / getVersion 变 → 扫描置脏）→ 精确计数 → 条件 → 有活吗 → 探测 + 桌面健康 →
//   申请 FGS + wakelock + 一条推送订阅。
// 循环每张：重检 → 取件（固定优先级：遗留续传 → 对账扫描 → 新照片 → 对账补传）→ 准备（已有 order 读 hash；
//   新照片调 MediaImporter.import）→ 传输（offer，桌面「已有」即完成）→ 提交（只有新照片推进 G，扫描只推进 S）。
// 取不到 → 释放 FGS、订阅、wakelock。
//
// 单写者（MOB-88 的思想保留）：所有状态变更都在 [scope] 上执行，而 [scope] 跑在一个单线程
// dispatcher 上（生产见 FlowWriter）。导入、读 MediaStore、走网络都 `withContext(io)` 出去，
// 挂起期间写者线程空出来处理别的命令（暂停、取消），所以不会被一张 4GB 视频卡住。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.GenerationAdvance
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
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class FlowEngine(
    private val store: OrderStore,
    private val media: MediaSnapshotSource,
    /** 原图 → 手机侧 iroh store（W3）。准备这一步唯一读文件的地方。 */
    private val importer: MediaImporter,
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
    // 写 `_status` 就是写原始运行态；要不要刷新通知 / 首页由 [LoopStatusCell] 按「值变了 + 节流」决定。
    private val _status = LoopStatusCell(scope, publish = { foreground.update(it) }, now = monotonicClock)

    /** 原始运行态：每次写入都是最新值（引擎判断、测试断言用）。 */
    val status: StateFlow<LoopStatus> = _status.raw

    /** 对外展示的运行态：值变了才发，字节进度每秒最多一次。FGS 通知读它。 */
    val display: StateFlow<LoopStatus> = _status.display

    /** 视图里除运行态之外的事实（暂停标志、等待原因、待办、本轮已完成、桌面健康）。 */
    private val facts = MutableStateFlow(ViewFacts(paused = control.paused(), waitReason = control.waitReason()))

    /**
     * #413 契约 §3：UI 与 FGS 通知读的唯一视图。暂停压过一切；在跑（含检查阶段）是 RUNNING；有等待原因是 WAITING；
     * 否则 IDLE。[EngineView.pending] 在第一次精确计数出来之前是 0——要区分「还不知道」用 [pendingKnown]。
     */
    val view: StateFlow<EngineView> = combine(_status.display, facts) { status, f -> engineViewOf(status, f) }
        .stateIn(scope, SharingStarted.Eagerly, engineViewOf(LoopStatus(), facts.value))

    private val known = MutableStateFlow(false)

    /** 第一次精确计数已经出来了（在这之前别让 UI 说「照片都存好了」）。 */
    val pendingKnown: StateFlow<Boolean> = known.asStateFlow()

    /** 每次 order / 意图写入后 +1：UI 投影据此重读账目。 */
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

    private fun audit(kind: String, payload: Map<String, String>) =
        AuditRecord(UUID.randomUUID().toString(), kind, null, clock(), payload)

    /** 等待原因：持久化（进程重启后还在）、进视图。 */
    private fun setWait(reason: WaitReason?) {
        control.setWaitReason(reason)
        facts.update { it.copy(waitReason = reason, paused = control.paused()) }
    }

    private fun setPausedFlag(paused: Boolean) {
        control.setPaused(paused)
        facts.update { it.copy(paused = paused) }
    }

    private fun setPending(n: Int) {
        facts.update { it.copy(pending = n.coerceAtLeast(0)) }
        known.value = true
    }

    // ---------------------------------------------------------------- 命令

    /** 进程启动：中断的那张保持「传输中」（下一轮遗留续传），这里只算一次待办。只跑一次。 */
    fun start(): Job = scope.launch {
        if (started) return@launch
        started = true
        refreshPending()
        bump()
    }

    /**
     * 任何触发的唯一入口：只叫醒循环（在跑就合并，D-02），不带「做什么」。
     * 暂停中只记意图（新增相册置脏、重算待办），不跑。
     */
    fun trigger(reason: TriggerReason): Job = scope.launch { onTrigger(reason) }

    /** 写者上执行。返回 true = 这次触发起了一轮新的循环。 */
    private suspend fun onTrigger(reason: TriggerReason): Boolean {
        // 新增相册的历史照片在 G 以下：扫描置脏。暂停中也要记下（暂停期间的变化只改意图，继续后待办现算）。
        if (reason == TriggerReason.SCOPE_ADDED) store.markScanDirty()
        if (control.paused()) {
            log.log("trigger $reason: paused by user, only intent recorded")
            refreshPending()
            return false
        }
        pending += reason
        if (cycleJob?.isActive == true) {
            log.log("trigger $reason coalesced into the running cycle")
            if (reason == TriggerReason.MEDIA_CHANGE || reason == TriggerReason.SCOPE_ADDED) refreshPending()
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
    private fun globalState(): GlobalState = when {
        control.paused() -> GlobalState.PAUSED
        cycleJob?.isActive == true -> GlobalState.RUNNING
        control.waitReason() != null -> GlobalState.WAITING
        else -> GlobalState.IDLE
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

    /**
     * 「取消剩余 N 张」弹窗那一刻的边界 + 张数（契约 §3）。与计数是**同一个差集**（范围内照片 − 跳过名单 − 已有结局），
     * 确认时交给 [cancelRemaining]：写下的正是这份边界里的照片，弹窗之后新拍的不在里面。
     */
    suspend fun remainingSnapshot(): RemainingSnapshot {
        val targets = withContext(io) { todoTargets() }
        scope.launch { setPending(targets.size) }
        return RemainingSnapshot(targets.size, clock(), targets)
    }

    /** 旧入口：弹窗上的 N。 */
    suspend fun countRemaining(): Int = remainingSnapshot().count

    /**
     * X-01 / 契约 §3：「取消剩余 N 张」，只在「已暂停」与「等待中」有效。一个事务把 [snapshot] 里的照片写进跳过名单、
     * 它们的在途 order 改成用户跳过；在飞的那张请桌面丢掉半截（`cancel_tuple`）；清除暂停标志 → 空闲。
     * 返回写进跳过名单的张数；不在允许的状态时返回 null。
     */
    fun cancelRemaining(snapshot: RemainingSnapshot): Deferred<Int?> = scope.async {
        val state = globalState()
        if (state != GlobalState.PAUSED && state != GlobalState.WAITING) {
            log.log("cancel ignored: state is $state")
            return@async null
        }
        pending.clear()
        cycleJob?.cancelAndJoin()
        val boundary = snapshot.targets.mapTo(HashSet()) { it.mediaId }
        val inFlight = store.currentInStates(setOf(OrderState.TRANSFERRING)).filter { it.mediaId in boundary }
        val result = store.cancelRemaining(
            snapshot.targets,
            audit = audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "cancel", "skipped" to snapshot.count.toString())),
        )
        inFlight.forEach { order -> delivery.discardPartial(order.id, PairingEpoch(order.pairingEpoch)) }
        log.log("cancel: ${result.written} photos skipped (${result.ordersSkipped} orders, ${result.untouched} settled since the dialog)")
        setPausedFlag(false)
        setWait(null)
        _status.value = LoopStatus(phase = LoopPhase.IDLE)
        refreshPending()
        bump()
        afterCycle()
        result.written
    }

    /**
     * #418「已跳过的照片 · 点击恢复」：一个事务清空跳过名单并把对账扫描置脏——这些照片在 G 以下，只有扫描取得到，
     * 待办现算自然包含它们。暂停中只改意图，继续之后接上。返回恢复了几张。
     */
    fun restoreSkipped(): Deferred<Int> = scope.async {
        val restored = store.restoreSkipped(audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "restore")))
        log.log("restore: $restored photos removed from the skip list; the reconcile scan will pick them up")
        bump()
        if (restored > 0 && !control.paused()) onTrigger(TriggerReason.RESTORE_SKIPPED) else refreshPending()
        restored
    }

    /** 用户点「重试」：当前 FAILED 改回待传输（不受兜底次数上限），然后叫醒循环。 */
    fun retryFailed(): Deferred<Int> = scope.async {
        val n = store.retryFailed(audit(AuditKinds.ROUND_CONTROLLED, mapOf("action" to "retry")))
        bump()
        onTrigger(TriggerReason.RETRY_FAILED)
        n
    }

    /** FGS 被系统收走（onTimeout）：记原因、停循环（端口发 flow.suspend）、等待中。下一次触发照常再申请（#413）。 */
    fun onForegroundLost(reason: FgsBlockReason = FgsBlockReason.BUDGET_EXHAUSTED): Job = scope.launch {
        control.recordFgsBlock(reason)
        log.log("foreground lost ($reason): stopping the loop; the next trigger may request it again")
        stopCycle(WaitReason.FGS_BLOCKED)
    }

    /** App 回到前台：一次触发（含对账）。 */
    fun onAppForeground(): Job = scope.launch { onTrigger(TriggerReason.APP_FOREGROUND) }

    /**
     * 网络变化回调：正在跑且条件已不满足（例如仅 Wi‑Fi 却切到了移动网络）→ 停掉循环、释放 FGS、
     * 登记约束唤醒；否则当作一次触发（路径失败之后网络回来，就是这一次触发把循环叫醒）。
     */
    fun onNetworkChanged(): Job = scope.launch {
        val running = cycleJob?.isActive == true
        val reason = waitReasonOf(conditions(), userPresent = false)
        if (running && reason == WaitReason.WIFI) {
            log.log("network changed: $reason no longer satisfied, stopping the loop")
            stopCycle(reason)
            scheduler.scheduleWhenConditionsMet(reason)
            return@launch
        }
        onTrigger(TriggerReason.NETWORK_CHANGE)
    }

    /**
     * #413：onLost（手机此刻没有任何可用网络）→ 在飞的这张立即判路径失败：停循环（端口尽力发 flow.suspend），
     * order 保持「传输中」可续传，等待中（桌面不可达）+ 3 次间隔 10 分钟的探测；网络回来时网络回调就是下一次触发。
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
            withContext(NonCancellable) {
                runCatching { refreshPending() }
                afterCycle()
            }
        }
    }

    private fun settle(wait: WaitReason?) {
        _status.value = LoopStatus(phase = LoopPhase.IDLE, waitReason = wait)
        setWait(wait)
        checksDone.update { it + 1 }
    }

    private suspend fun runCycle(reasons: Set<TriggerReason>) {
        val userPresent = reasons.any { it.userPresent }
        val reconcile = reasons.any { it.reconcile }
        _status.value = LoopStatus(phase = LoopPhase.CHECKING)
        if (control.paused()) return settle(null)
        val epoch = pairingEpoch() ?: return settle(WaitReason.NOT_PAIRED)

        // ---- 入口：不持有 FGS，只读元数据 ----
        val cycleStarted = System.nanoTime()
        prepareCursors(reconcile)
        val todo = withContext(io) { countTodo() }
        setPending(todo)
        log.log("cycle $reasons: check count took ${msSince(cycleStarted)}ms pending=$todo")
        waitReasonOf(conditions(), userPresent)?.let { reason ->
            log.log("cycle $reasons: waiting for $reason (no foreground service requested)")
            if (reason == WaitReason.WIFI || reason == WaitReason.BATTERY) scheduler.scheduleWhenConditionsMet(reason)
            return settle(reason)
        }
        if (!hasWork(reconcile)) {
            log.log("cycle $reasons: nothing to transfer")
            return settle(null)
        }
        val probeStarted = System.nanoTime()
        val reach = withContext(io) { probe.probe() }
        log.log("cycle $reasons: check probe took ${msSince(probeStarted)}ms result=${reach.javaClass.simpleName} sinceCycleStartMs=${msSince(cycleStarted)}")
        when (reach) {
            ProbeResult.Unreachable -> {
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

        // ---- 申请 FGS + wakelock：整轮只申请这一次（C-06）；被拒就等下一次触发 ----
        if (!foreground.acquire()) {
            control.recordFgsBlock(FgsBlockReason.START_REFUSED)
            log.log("foreground service refused: waiting; the next trigger requests it again")
            return settle(WaitReason.FGS_BLOCKED)
        }
        _status.value = LoopStatus(phase = LoopPhase.RUNNING)
        setWait(null)
        facts.update { it.copy(doneThisRound = 0) }
        checksDone.update { it + 1 }
        var exit: WaitReason? = null
        try {
            // 一轮一条推送订阅（契约 §5），随 FGS 一起释放。
            exit = delivery.session { loop(Round(reconcile, userPresent)) }
        } finally {
            withContext(NonCancellable) {
                foreground.release()
                bump()
                if (!control.paused()) settle(exit) else _status.value = LoopStatus(phase = LoopPhase.IDLE)
            }
        }
    }

    /**
     * 入口：游标就位。G 缺失（新装、新卷、换桌面清库）或 getVersion 变了（MediaStore 重建）→ G 从当前最大
     * generation 起步、扫描置脏：已有的照片交给扫描（按 `_id`），新照片仍然按 G。generation 不精确（API < 30）
     * 时对账轮每次都扫。只读元数据。
     */
    private suspend fun prepareCursors(reconcile: Boolean) {
        val (volumes, versions) = withContext(io) { media.volumeNames() to media.volumeVersions() }
        for (volume in volumes) {
            val state = store.volumeState(volume)
            val version = versions[volume]
            if (state == null || (version != null && state.mediaStoreVersion != version)) {
                val max = withContext(io) { media.maxGeneration(volume) }
                store.saveVolumeState(VolumeState(volume, max, Long.MAX_VALUE, version))
                store.markScanDirty()
                log.log("volume $volume: ${if (state == null) "no cursor yet" else "MediaStore version changed"}; G=$max, reconcile scan marked dirty")
            }
        }
        if (reconcile && !media.preciseGeneration) store.markScanDirty()
    }

    /** 入口：这一轮有没有可能取到东西（不读文件、不走网络）。没有就不申请 FGS。 */
    private suspend fun hasWork(reconcile: Boolean): Boolean {
        if (store.currentInStates(setOf(OrderState.TRANSFERRING, OrderState.PENDING), limit = 1).isNotEmpty()) return true
        if (store.scanState().dirty) return true
        if (discoveryStep() != null) return true
        if (!reconcile) return false
        if (store.currentInStates(setOf(OrderState.FAILED)).any { it.attempts < OrderStore.MAX_FAILURES }) return true
        return store.confirmedWithHashAfter(0L, 1).isNotEmpty()
    }

    /** 一轮之内的取件状态。 */
    private class Round(val reconcile: Boolean, val userPresent: Boolean) {
        var legacyAfter = 0L
        var retryAfter = 0L
        var presenceDone = !reconcile
        val handled = HashSet<Long>()
    }

    /** 逐张循环本体。返回退出原因（null = 取不到下一张，正常结束）。 */
    private suspend fun loop(round: Round): WaitReason? {
        while (true) {
            // C-07：每张开始前重检条件，并确认 FGS 仍然有效。
            if (control.paused()) return null
            waitReasonOf(conditions(), round.userPresent)?.let { reason ->
                if (reason == WaitReason.WIFI || reason == WaitReason.BATTERY) scheduler.scheduleWhenConditionsMet(reason)
                return reason
            }
            if (!foreground.isHeld()) return WaitReason.FGS_BLOCKED
            val epoch = pairingEpoch() ?: return WaitReason.NOT_PAIRED
            val item = pickNext(round) ?: return null
            if (item is WorkItem.Existing && !round.handled.add(item.order.id)) {
                log.log("order ${item.order.id} picked twice in one round; stopping to avoid a spin")
                return null
            }
            when (val step = process(item, epoch)) {
                StepResult.Next -> Unit
                is StepResult.Exit -> return step.reason
            }
            foreground.renew()
        }
    }

    // ---------------------------------------------------------------- 取件

    /** 这一张从哪个来源取的：决定提交时推进哪个游标。 */
    private enum class Origin { LEGACY, SCAN, DISCOVERY, RETRY }

    private sealed interface WorkItem {
        data class Existing(val order: Order, val origin: Origin) : WorkItem
        data class Fresh(val snapshot: MediaSnapshot, val origin: Origin) : WorkItem
    }

    private sealed interface StepResult {
        data object Next : StepResult
        data class Exit(val reason: WaitReason) : StepResult
    }

    /** 取件固定优先级：遗留续传 → 对账扫描 → 新照片 → 对账补传（待传输 / 失败重试 / 桌面缺失）。 */
    private suspend fun pickNext(round: Round): WorkItem? {
        while (true) {
            store.currentInStates(setOf(OrderState.TRANSFERRING), afterId = round.legacyAfter, limit = 1).firstOrNull()?.let {
                round.legacyAfter = it.id
                return WorkItem.Existing(it, Origin.LEGACY)
            }
            scanStep()?.let { return it }
            discoveryStep()?.let { return it }
            val states = if (round.reconcile) setOf(OrderState.PENDING, OrderState.FAILED) else setOf(OrderState.PENDING)
            val batch = store.currentInStates(states, afterId = round.retryAfter, limit = RETRY_BATCH)
            for (order in batch) {
                round.retryAfter = order.id
                if (order.state == OrderState.FAILED && order.attempts >= OrderStore.MAX_FAILURES) continue
                return WorkItem.Existing(order, Origin.RETRY)
            }
            if (batch.isNotEmpty()) continue
            if (!round.presenceDone) {
                round.presenceDone = true
                if (runRemotePresence() > 0) continue
            }
            return null
        }
    }

    /**
     * 这张照片要不要由扫描 / 发现来源建一行新 order：不在跳过名单里，且当前行不是同版本的「已有结局」
     * 或「还在路上」（后者由遗留续传 / 对账补传来源负责）。恢复过的（当前行是用户跳过、名单里已经没有）要。
     */
    private fun needsNewOrder(snapshot: MediaSnapshot): Boolean {
        if (store.isSkipped(snapshot.mediaId)) return false
        val current = store.currentForMedia(snapshot.mediaId) ?: return true
        if (current.sourceVersion != snapshot.sourceVersion) return true
        return current.state == OrderState.SKIPPED_BY_USER
    }

    /** 对账扫描（脏时才是来源）：按 `_id` 从 S 往后，跳过的照片批量推进 S；扫到末尾清脏。 */
    private suspend fun scanStep(): WorkItem? {
        while (true) {
            val scan = store.scanState()
            if (!scan.dirty) return null
            val batch = withContext(io) { media.readInScope(scan.cursor) { it.take(SOURCE_BATCH).toList() } }
            if (batch.isEmpty()) {
                store.finishScan()
                log.log("reconcile scan finished")
                return null
            }
            var skippedTo: Long? = null
            for (snapshot in batch) {
                if (needsNewOrder(snapshot)) {
                    skippedTo?.let(store::advanceScan)
                    return WorkItem.Fresh(snapshot, Origin.SCAN)
                }
                skippedTo = snapshot.mediaId
            }
            skippedTo?.let(store::advanceScan)
        }
    }

    /** 发现：每个卷按 G 取新照片（D-01：按 (generation, `_id`) 升序、不插队），不需要动作的批量推进 G。 */
    private suspend fun discoveryStep(): WorkItem? {
        for (volume in withContext(io) { media.volumeNames() }) {
            while (true) {
                val g = store.volumeState(volume) ?: break
                val batch = withContext(io) { media.readChangedSince(volume, g.generation, g.generationMediaId) { it.take(SOURCE_BATCH).toList() } }
                if (batch.isEmpty()) break
                var skippedTo: GenerationAdvance? = null
                for (snapshot in batch) {
                    if (needsNewOrder(snapshot)) {
                        skippedTo?.let(store::advanceGeneration)
                        return WorkItem.Fresh(snapshot.copy(volumeName = volume), Origin.DISCOVERY)
                    }
                    skippedTo = GenerationAdvance(volume, snapshot.generation, snapshot.mediaId)
                }
                skippedTo?.let(store::advanceGeneration)
            }
        }
        return null
    }

    // ---------------------------------------------------------------- 准备 → 传输 → 提交

    /** 提交时推进哪个游标：只有新照片推进 G，扫描只推进 S，已有 order 什么都不推进。 */
    private data class Progress(val advance: GenerationAdvance? = null, val scanTo: Long? = null)

    private fun progressOf(snapshot: MediaSnapshot, origin: Origin) = when (origin) {
        Origin.DISCOVERY -> Progress(advance = GenerationAdvance(snapshot.volumeName, snapshot.generation, snapshot.mediaId))
        Origin.SCAN -> Progress(scanTo = snapshot.mediaId)
        else -> Progress()
    }

    private fun Progress.write() {
        advance?.let(store::advanceGeneration)
        scanTo?.let(store::advanceScan)
    }

    private suspend fun process(item: WorkItem, epoch: PairingEpoch): StepResult = when (item) {
        is WorkItem.Existing -> processExisting(item.order, epoch)
        is WorkItem.Fresh -> processFresh(item.snapshot, item.origin, epoch)
    }

    /** 导入（准备这一步唯一读文件的地方），单张失败当场重试 1 次。first = null 表示两次都抛了，second 是原因。 */
    private suspend fun importWithRetry(details: MediaDetails): Pair<ImportResult?, String> {
        var reason = "import"
        repeat(2) { attempt ->
            try {
                return withContext(io) { importer.import(details.snapshot.mediaId, details.uri, details.dataPath) } to reason
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                reason = "import:${failure.javaClass.simpleName}"
                log.log("media ${details.snapshot.mediaId}: import failed (${failure.message})${if (attempt == 0) "; retrying once" else ""}")
            }
        }
        return null to reason
    }

    private suspend fun processFresh(snapshot: MediaSnapshot, origin: Origin, epoch: PairingEpoch): StepResult {
        val progress = progressOf(snapshot, origin)
        val details = withContext(io) { media.lookup(snapshot.mediaId) }
        if (details == null || !inScope(details.snapshot.bucketId)) {
            progress.write()
            return StepResult.Next
        }
        val version = details.snapshot.sourceVersion
        val bucket = details.snapshot.bucketId
        val (imported, failure) = importWithRetry(details)
        when (imported) {
            null -> {
                // 读不出来（两次）：记一次失败（有上限），游标照常推进，不在这张上打转。
                val row = store.insert(NewOrder(snapshot.mediaId, version, bucket, null, OrderState.TRANSFERRING, epoch.value))
                fail(row.id, progress, failure)
                return StepResult.Next
            }
            ImportResult.SourceMissing -> {
                // MediaStore 还列着、文件读不到：记「源已删」（同版本即结局，不再算待办），游标推进。
                store.insert(
                    NewOrder(snapshot.mediaId, version, bucket, null, OrderState.SKIPPED_SOURCE_MISSING, epoch.value),
                    advance = progress.advance,
                    scanTo = progress.scanTo,
                    audit = audit(AuditKinds.ITEM_SOURCE_MISSING, mapOf("mediaId" to snapshot.mediaId.toString())),
                )
                onSettled()
                bump()
                return StepResult.Next
            }
            is ImportResult.Imported -> {
                // 引用导入算出 hash → 建 order（传输中，带 hash）→ 传输。G / S 在结局落库时一起推进（#415 裁决 8）。
                val row = store.insert(NewOrder(snapshot.mediaId, version, bucket, imported.contentHash, OrderState.TRANSFERRING, epoch.value))
                bump()
                return deliverAndCommit(row, imported.contentHash, details, progress, epoch)
            }
        }
    }

    /**
     * 已有 order（遗留续传 / 对账补传）：开始前按原图、版本、范围重检；重新导入（暂停 / revoke 会放掉全部导入）
     * 拿 hash 与行里记的比对，通过后置为传输中。已有 order 提交时**不推进任何游标**。
     */
    private suspend fun processExisting(order: Order, epoch: PairingEpoch): StepResult {
        val transferring = order.state == OrderState.TRANSFERRING
        val details = withContext(io) { media.lookup(order.mediaId) }
        if (details == null || details.snapshot.sourceVersion != order.sourceVersion) {
            // 原图没了；或中断期间被编辑成了新版本——这一行描述的版本已不存在，新版本由扫描 / 发现另起一行。
            settleSourceMissing(order, if (details == null) "gone" else "version_changed", discard = transferring)
            return StepResult.Next
        }
        if (!inScope(details.snapshot.bucketId)) {
            // 在途的这张所在相册被移出范围：不续传，丢弃半截（#413 裁定 8）；它从待办里消失（范围是查询条件）。
            if (transferring && store.transition(order.id, setOf(OrderState.TRANSFERRING), OrderState.PENDING)) {
                delivery.discardPartial(order.id, epoch)
                bump()
            }
            return StepResult.Next
        }
        val (imported, failure) = importWithRetry(details)
        val hash = when (imported) {
            null -> {
                if (store.transition(order.id, OPEN, OrderState.TRANSFERRING)) fail(order.id, Progress(), failure)
                return StepResult.Next
            }
            ImportResult.SourceMissing -> {
                settleSourceMissing(order, "gone", discard = transferring)
                return StepResult.Next
            }
            is ImportResult.Imported -> imported.contentHash
        }
        if (order.contentHash != null && order.contentHash != hash) {
            // 旧版本停在传输中（中断期间被编辑、MediaStore 版本没跟上）：直接舍弃——源已删 + cancel_tuple。
            importer.release(hash)
            settleSourceMissing(order, "content_changed", discard = true)
            return StepResult.Next
        }
        if (!store.transition(order.id, OPEN, OrderState.TRANSFERRING, contentHash = hash)) {
            importer.release(hash)
            return StepResult.Next
        }
        val row = store.get(order.id)!!.copy(contentHash = hash)
        return deliverAndCommit(row, hash, details, Progress(), epoch)
    }

    private suspend fun settleSourceMissing(order: Order, reason: String, discard: Boolean) {
        if (store.transition(
                order.id,
                OPEN,
                OrderState.SKIPPED_SOURCE_MISSING,
                audit = audit(AuditKinds.ITEM_SOURCE_MISSING, mapOf("queueSequence" to order.id.toString(), "reason" to reason)),
            )
        ) {
            if (discard) delivery.discardPartial(order.id, PairingEpoch(order.pairingEpoch))
            bump()
        }
    }

    private suspend fun deliverAndCommit(order: Order, hash: String, details: MediaDetails, progress: Progress, epoch: PairingEpoch): StepResult {
        val request = DeliveryRequest(order.id, epoch, hash, details)
        _status.value = LoopStatus(LoopPhase.RUNNING, CurrentItem(order.id, details.fileName, 0L, details.sizeBytes))
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
                    fail(order.id, progress, "receipt_mismatch")
                } else if (store.transition(
                        order.id,
                        setOf(OrderState.TRANSFERRING),
                        OrderState.CONFIRMED,
                        advance = progress.advance,
                        scanTo = progress.scanTo,
                        // E-01 / O-07：CONFIRMED、hash 映射（行本身）、游标推进、确认审计——同一次写入。
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
                ) {
                    facts.update { it.copy(doneThisRound = it.doneThisRound + 1) }
                    onSettled()
                }
                bump()
                StepResult.Next
            }
            DeliveryOutcome.SourceMissing -> {
                // 原图在供数期间被删 / 被改：源已删，不计失败；丢弃桌面半截、放掉导入。
                importer.release(hash)
                if (store.transition(
                        order.id,
                        setOf(OrderState.TRANSFERRING),
                        OrderState.SKIPPED_SOURCE_MISSING,
                        advance = progress.advance,
                        scanTo = progress.scanTo,
                        audit = audit(AuditKinds.ITEM_SOURCE_MISSING, mapOf("queueSequence" to order.id.toString())),
                    )
                ) {
                    delivery.discardPartial(order.id, epoch)
                    onSettled()
                }
                bump()
                StepResult.Next
            }
            is DeliveryOutcome.ItemFailure -> {
                importer.release(hash)
                fail(order.id, progress, outcome.reason)
                StepResult.Next
            }
            is DeliveryOutcome.PathFailure -> {
                // C-05 / C-10：路径失败——order 保持「传输中」可续传，不计次数，退出循环、登记探测。
                log.log("order ${order.id}: path failure (${outcome.reason}); leaving it resumable")
                scheduler.scheduleUnreachableProbes()
                StepResult.Exit(WaitReason.DESKTOP_UNREACHABLE)
            }
            is DeliveryOutcome.PeerFailure -> {
                // 契约 §5：对端失败——退出循环，不计次数，原因带回手机显示，等下一次唤醒。
                log.log("order ${order.id}: desktop cannot store it (${outcome.kind}/${outcome.code}); waiting for the next wake")
                StepResult.Exit(waitReasonOf(outcome.kind))
            }
            DeliveryOutcome.PairingLost -> StepResult.Exit(WaitReason.NOT_PAIRED)
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

    private fun fail(orderId: Long, progress: Progress, reason: String) {
        // #418：这里是「一张照片记为 FAILED」的唯一调用点，失败通知（FailureNotifier / SystemFailureNotifier，
        // 代码保留）**故意不在这里调用**：
        //  1. 失败要先按 路径 / 单张 / 对端 分类（#410 / #413 契约 §5）——分类刚落地，各类的真机比例还没看过，
        //     现在推给用户的「备份失败」多半是误报（待分类确认后再决定哪一类要通知）；
        //  2. 兜底对账会自动再试一次 FAILED——现在就推通知，大多数是会自愈的问题。
        // 结构测试 ARCH14UiWiringTest.the_failure_notification_is_kept_but_never_posted 锁住「main 里没有 postFailure 调用点」。
        store.transition(
            orderId,
            setOf(OrderState.TRANSFERRING),
            OrderState.FAILED,
            countAttempt = true,
            advance = progress.advance,
            scanTo = progress.scanTo,
            audit = audit(AuditKinds.ITEM_ATTENTION, mapOf("reason" to reason, "queueSequence" to orderId.toString())),
        )
        bump()
    }

    /** 这张照片有了结局、离开待办。 */
    private fun onSettled() {
        facts.update { it.copy(pending = (it.pending - 1).coerceAtLeast(0)) }
    }

    // ---------------------------------------------------------------- 对账补传：桌面缺失

    /**
     * 对账（O-08，持有 FGS 之后、对账轮里一次）：分页问桌面「已确认的这些还在吗」。缺的且原图还在、在范围内 →
     * **新建一行**待传输（桌面对已完成的同编号直接回完成，不会重拉，所以不能复用原 order id）；原图也没了 →
     * 只记审计 `unrecoverable`（#415 裁决 2）。返回新建了几行。
     */
    private suspend fun runRemotePresence(): Int {
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
                log.log("presence probe failed (${unreachable.javaClass.simpleName}); retrying next reconcile round")
                break
            }
            for (order in page) {
                val hash = order.contentHash ?: continue
                if (hash !in missing || !inScope(order.bucketId)) continue
                if (order.sourceMissing) {
                    store.appendAudit(audit(AuditKinds.RECONCILIATION_RESOLVED, mapOf("disposition" to "UNRECOVERABLE", "contentHash" to hash)))
                } else {
                    store.insert(
                        NewOrder(order.mediaId, order.sourceVersion, order.bucketId, hash, OrderState.PENDING, order.pairingEpoch),
                        audit = audit(AuditKinds.RECONCILIATION_RESOLVED, mapOf("disposition" to "REUPLOAD", "contentHash" to hash)),
                    )
                    requeued++
                }
            }
            after = page.last().id
        }
        if (requeued > 0) {
            log.log("presence: desktop is missing $requeued confirmed photos; re-uploading")
            facts.update { it.copy(pending = it.pending + requeued) }
        }
        bump()
        return requeued
    }

    // ---------------------------------------------------------------- 待办（现算）

    /** 在写者上重算待办并发进视图。 */
    private suspend fun refreshPending() {
        setPending(withContext(io) { countTodo() })
    }

    /** 这张（这个版本）是不是待办：不在跳过名单里，且当前行不是同版本的结局。 */
    private fun isTodo(snapshot: MediaSnapshot, current: Order?, skipped: Boolean): Boolean =
        !skipped && !(current != null && current.sourceVersion == snapshot.sourceVersion && current.state.isSettled)

    /**
     * 精确的待办张数（只读元数据）。
     * - 扫描脏时（新相册 / 恢复 / 重建之后，G 以下可能有待办）：全量差集，与 [todoTargets] 同一个函数。
     * - 不脏时：G 以下没有漏网的，待办只可能是「新照片（G 之后）」或「当前行还在路上（待传输 / 传输中 / 失败）」——
     *   两部分按 media_id 去重（中断的新照片两边都在），所以互斥、不重复。
     */
    private fun countTodo(): Int {
        if (store.scanState().dirty) return todoTargets().size
        val todo = HashSet<Long>()
        for (volume in media.volumeNames()) {
            val g = store.volumeState(volume) ?: continue
            media.readChangedSince(volume, g.generation, g.generationMediaId) { snapshots ->
                snapshots.forEach { s -> if (isTodo(s, store.currentForMedia(s.mediaId), store.isSkipped(s.mediaId))) todo += s.mediaId }
            }
        }
        for (order in store.currentInStates(OPEN)) {
            if (order.mediaId in todo || store.isSkipped(order.mediaId)) continue
            val details = media.lookup(order.mediaId) ?: continue
            if (inScope(details.snapshot.bucketId)) todo += order.mediaId
        }
        return todo.size
    }

    /** 全量差集：范围内照片（按 `_id`）× 当前行（按 media_id）× 跳过名单（按 media_id），三路归并，只读元数据。 */
    private fun todoTargets(): List<SkipTarget> {
        val out = ArrayList<SkipTarget>()
        media.readInScope(0L) { snapshots ->
            store.readCurrentOrders { orders ->
                store.readSkipList { skips ->
                    val o = orders.iterator()
                    val k = skips.iterator()
                    var order = if (o.hasNext()) o.next() else null
                    var skip = if (k.hasNext()) k.next() else null
                    for (s in snapshots) {
                        while (order != null && order.mediaId < s.mediaId) order = if (o.hasNext()) o.next() else null
                        while (skip != null && skip < s.mediaId) skip = if (k.hasNext()) k.next() else null
                        val current = order?.takeIf { it.mediaId == s.mediaId }
                        if (isTodo(s, current, skip == s.mediaId)) out += SkipTarget(s.mediaId, s.sourceVersion, s.bucketId)
                    }
                }
            }
        }
        return out
    }

    companion object {
        private const val SOURCE_BATCH = 64
        private const val RETRY_BATCH = 32
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

/** 暂停压过一切；在跑（含检查阶段）是 RUNNING；有等待原因是 WAITING；否则 IDLE。 */
internal fun engineViewOf(status: LoopStatus, facts: ViewFacts): EngineView {
    val state = when {
        facts.paused -> GlobalState.PAUSED
        status.phase != LoopPhase.IDLE -> GlobalState.RUNNING
        facts.waitReason != null -> GlobalState.WAITING
        else -> GlobalState.IDLE
    }
    return EngineView(
        state = state,
        waitReason = facts.waitReason.takeIf { state == GlobalState.WAITING },
        pending = facts.pending,
        doneThisRound = facts.doneThisRound,
        current = status.current.takeIf { state == GlobalState.RUNNING && status.running },
        desktopHealth = facts.desktopHealth,
    )
}
