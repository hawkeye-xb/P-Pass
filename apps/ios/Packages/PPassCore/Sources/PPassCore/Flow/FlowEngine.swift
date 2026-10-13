// #891：逐张循环（对位 Android `flow/FlowEngine.kt`，依赖倒置：循环不认识「哪类照片」，只认识「取件来源」）。
//
// 入口（不持有执行租约、不读文件、不做 presence 网络请求）：
//   暂停？→ 游标就位（G 缺失 / 照片库换了 → 扫描置脏）→ 精确计数 → 条件 → 有活吗 → 探测 + 桌面健康 →
//   申请执行租约 + 一条推送订阅。
// 循环每张：重检 → 取件（固定优先级：遗留续传 → 对账扫描 → 新照片 → 对账补传）→ 准备（已有 order 重新导入比 hash；
//   新照片导入算 hash）→ 传输（offer，桌面「已有」即完成）→ 提交（只有新照片推进 G，扫描只推进 S）。
// 取不到 → 释放租约、订阅。
//
// 单写者：引擎是一个 actor，所有状态变更都在它上面顺序发生（Android 是单线程 dispatcher）。导入、读照片库、走网络都是
// `await` 出去，挂起期间 actor 空出来处理别的命令（暂停、取消），所以不会被一张 4GB 视频卡住。
//
// 取消语义（与 Kotlin 不同，必须显式）：Kotlin 在任何挂起点被取消都会抛 CancellationException；Swift 不会。
// 所以每个 `await` 端口调用之后都 `try Task.checkCancellation()`，与 Kotlin 会抛的位置一一对应。取消之后还要做的收尾
// （重算待办、审计冲刷）放进一个不继承取消的非结构化 Task 里等它完成——对位 `withContext(NonCancellable)`。
import Foundation

public actor FlowEngine {
    // MARK: 注入

    private let store: OrderStore
    private let media: MediaSource
    private let importer: MediaImporter
    private let delivery: ItemDelivery
    private let probe: DesktopProbe
    private let presence: RemotePresence
    private let lease: ExecutionLease
    private let scheduler: WakeScheduler
    private let control: FlowControl
    private let conditions: @Sendable () -> Conditions
    private let inScope: @Sendable (String) -> Bool
    /// #459：「照片库里查不到」此刻能不能当「原图被删了」。只有完整相册权限才是 true。**没有默认值**（失败关闭）。
    private let mediaAbsenceTrusted: @Sendable () -> Bool
    /// 当前配对代号；nil = 未配对。
    private let pairingEpoch: @Sendable () -> String?
    private let logger: CoreLogger
    /// 墙钟（审计时间戳）。
    private let clock: @Sendable () -> Int64
    /// 单调时钟（ms），只给进度节流用。
    private let monotonic: @Sendable () -> Int64
    /// 每轮结束后（审计 outbox 冲刷等）。
    private let afterCycle: @Sendable () async -> Void
    /// 桌面宣布了新的配对代号（同一台桌面重新配对）：持久化它。
    private let onEpochAdvertised: @Sendable (String) -> Void
    /// 视图变化的出口（UI 投影订阅它）。
    private let onView: @Sendable (EngineView) -> Void

    // MARK: 状态（只在 actor 上读写）

    private var status = LoopStatus()
    private var paused: Bool
    private var waitReason: WaitReason?
    private var pending = 0
    private var doneThisRound = 0
    private var desktopHealth: DesktopHealth?
    /// 第一次精确计数已经出来了（在这之前别让 UI 说「照片都存好了」）。
    public private(set) var pendingKnown = false
    /// 每次 order / 意图写入后 +1：UI 投影据此重读账目。
    public private(set) var revision: Int64 = 0

    private var cycleTask: Task<Void, Never>?
    private var cycleActive = false
    private var pendingTriggers: [TriggerReason] = []
    private var started = false
    /// AUDIT-07：这一轮已经发出的逐张事实计数（键 == 桌面 `audit_item_evidence.outcome`）。
    private var roundOutcomes: [String: Int] = [:]
    private var lastPublished: EngineView?
    private var lastPublishedAt: Int64 = .min

    static let sourceBatch = 64
    static let retryBatch = 32
    static let countPage = 256
    static let presencePage = 500
    static let progressRefreshMs: Int64 = 1_000
    /// 在跑时合并进来的这些触发意味着待办可能变了：当场重算（只读元数据），不等这一轮结束。
    static let recountWhileRunning: Set<TriggerReason> = [.mediaChange, .foregroundMediaChange, .scopeAdded, .appForeground]

    public init(
        store: OrderStore,
        media: MediaSource,
        importer: MediaImporter,
        delivery: ItemDelivery,
        probe: DesktopProbe,
        presence: RemotePresence,
        lease: ExecutionLease,
        scheduler: WakeScheduler,
        control: FlowControl,
        conditions: @escaping @Sendable () -> Conditions,
        inScope: @escaping @Sendable (String) -> Bool,
        mediaAbsenceTrusted: @escaping @Sendable () -> Bool,
        pairingEpoch: @escaping @Sendable () -> String?,
        logger: CoreLogger,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        monotonic: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        afterCycle: @escaping @Sendable () async -> Void = {},
        onEpochAdvertised: @escaping @Sendable (String) -> Void = { _ in },
        onView: @escaping @Sendable (EngineView) -> Void = { _ in }
    ) {
        self.store = store
        self.media = media
        self.importer = importer
        self.delivery = delivery
        self.probe = probe
        self.presence = presence
        self.lease = lease
        self.scheduler = scheduler
        self.control = control
        self.conditions = conditions
        self.inScope = inScope
        self.mediaAbsenceTrusted = mediaAbsenceTrusted
        self.pairingEpoch = pairingEpoch
        self.logger = logger
        self.clock = clock
        self.monotonic = monotonic
        self.afterCycle = afterCycle
        self.onEpochAdvertised = onEpochAdvertised
        self.onView = onView
        paused = control.paused()
        waitReason = control.waitReason()
    }

    private func log(_ message: String) { logger.log(message) }

    // MARK: 视图

    /// UI 与执行租约通知读的唯一视图。暂停压过一切；在跑（含检查阶段）是 RUNNING；有等待原因是 WAITING；否则 IDLE。
    public var view: EngineView {
        let state: GlobalState
        if paused {
            state = .paused
        } else if status.phase != .idle {
            state = .running
        } else if waitReason != nil {
            state = .waiting
        } else {
            state = .idle
        }
        return EngineView(
            state: state,
            waitReason: state == .waiting ? waitReason : nil,
            pending: pending,
            doneThisRound: doneThisRound,
            current: state == .running && status.phase == .running ? status.current : nil,
            desktopHealth: desktopHealth
        )
    }

    /// 值变了才发；只有字节进度变了的，每秒最多一次。
    private func publish() {
        let v = view
        guard v != lastPublished else { return }
        let now = monotonic()
        if let last = lastPublished, onlyProgressDiffers(last, v), now - lastPublishedAt < Self.progressRefreshMs { return }
        lastPublished = v
        lastPublishedAt = now
        lease.update(status)
        onView(v)
    }

    private func onlyProgressDiffers(_ a: EngineView, _ b: EngineView) -> Bool {
        var a2 = a, b2 = b
        a2.current?.bytesSent = 0
        b2.current?.bytesSent = 0
        return a2 == b2 && a.current?.bytesSent != b.current?.bytesSent
    }

    private func setStatus(_ s: LoopStatus) {
        status = s
        publish()
    }

    private func bump() {
        revision += 1
    }

    private func setWait(_ reason: WaitReason?) {
        control.setWaitReason(reason)
        waitReason = reason
        paused = control.paused()
        publish()
    }

    private func setPausedFlag(_ value: Bool) {
        control.setPaused(value)
        paused = value
        publish()
    }

    private func setPending(_ n: Int) {
        pending = max(0, n)
        pendingKnown = true
        publish()
    }

    private func globalState() -> GlobalState {
        if control.paused() { return .paused }
        if cycleActive { return .running }
        if control.waitReason() != nil { return .waiting }
        return .idle
    }

    // MARK: 审计

    /// 一条审计事实。`round_id` 一律取**当前未闭合的那一轮**（AUDIT-07）；不在任何一轮里的事实为 nil。
    private func audit(_ kind: String, _ payload: [String: String], roundId: String?? = .none) -> AuditRecord {
        let rid: String?
        switch roundId {
        case .none: rid = (try? store.openRoundId()) ?? nil
        case let .some(explicit): rid = explicit
        }
        return AuditRecord(eventId: UUID().uuidString.lowercased(), kind: kind, roundId: rid, occurredAtMs: clock(), payload: payload)
    }

    /// AUDIT-06：逐张审计一律带 `itemRef`（`media:<id>`），桌面据此落逐张证据。
    private func itemAudit(_ kind: String, _ mediaId: String, _ payload: [String: String]) -> AuditRecord {
        audit(kind, payload.merging(["itemRef": "media:\(mediaId)"]) { a, _ in a })
    }

    /// 这条事实**已经写进 outbox** 之后才计入本轮自报计数（Android 在构造审计时就计，转换失败时会多算一条）。
    private func countOutcome(_ record: AuditRecord) {
        let outcome: String?
        switch record.kind {
        case AuditKinds.itemConfirmed: outcome = "confirmed"
        case AuditKinds.itemSourceMissing: outcome = "source_missing"
        case AuditKinds.itemAttention: outcome = "failed"
        case AuditKinds.reconciliationResolved: outcome = record.payload["disposition"] == "UNRECOVERABLE" ? nil : "remote_missing"
        default: outcome = nil
        }
        if let outcome { roundOutcomes[outcome, default: 0] += 1 }
    }

    private func finishedAudit(_ roundId: String, _ counts: [String: String]) -> AuditRecord {
        AuditRecord(eventId: UUID().uuidString.lowercased(), kind: AuditKinds.roundFinished, roundId: roundId, occurredAtMs: clock(), payload: counts)
    }

    // MARK: 命令

    /// 进程启动：中断的那张保持「传输中」（下一轮遗留续传），这里只算一次待办。只跑一次。
    public func start() async {
        if started { return }
        started = true
        // AUDIT-07：上一次进程被杀掉时留下的未闭合轮——先替它补上终态（不带计数：桌面按证据自己重算）。
        if let abandoned = (try? store.openRoundId()) ?? nil {
            log("round \(abandoned): closing the round a killed process left open")
            do { try store.closeRound(finishedAudit(abandoned, [:])) } catch { log("round \(abandoned): close failed (\(error))") }
        }
        await refreshPending()
        bump()
    }

    /// 任何触发的唯一入口：只叫醒循环（在跑就合并，D-02）。暂停中只记意图（新增相册置脏、重算待办），不跑。
    /// 返回 true = 这次触发起了一轮新的循环。
    @discardableResult
    public func trigger(_ reason: TriggerReason) async -> Bool {
        if reason == .scopeAdded {
            do { try store.markScanDirty() } catch { log("trigger \(reason): mark scan dirty failed (\(error))") }
        }
        if control.paused() {
            log("trigger \(reason.rawValue): paused by user, only intent recorded")
            await refreshPending()
            return false
        }
        if !pendingTriggers.contains(reason) { pendingTriggers.append(reason) }
        if cycleActive {
            log("trigger \(reason.rawValue) coalesced into the running cycle")
            if Self.recountWhileRunning.contains(reason) { await refreshPending() }
            return false
        }
        startCycle()
        return true
    }

    private func startCycle() {
        cycleActive = true
        cycleTask = Task { await self.drain() }
    }

    private func cancelAndJoinCycle() async {
        guard let task = cycleTask else { return }
        task.cancel()
        await task.value
    }

    /// 测试与关停用：等当前这一轮（含合并进来的触发）跑完。
    public func awaitIdle() async {
        while let task = cycleTask {
            await task.value
            if cycleTask == nil || !cycleActive { break }
        }
    }

    /// C-01：暂停只在「备份中」有效。写暂停标志 → 退出循环（传输端口在取消时同步发 `flow.suspend`）→ 释放租约。
    @discardableResult
    public func pause() async -> Bool {
        guard globalState() == .running else {
            log("pause ignored: not running (\(globalState().rawValue))")
            return false
        }
        // AUDIT-07：先记下被打断的那一轮——「暂停」决策要挂到它身上。
        let interrupted = (try? store.openRoundId()) ?? nil
        setPausedFlag(true)
        pendingTriggers.removeAll()
        await cancelAndJoinCycle()
        do { try store.appendAudit(audit(AuditKinds.roundControlled, ["action": "pause"], roundId: .some(interrupted))) } catch { log("pause: audit failed (\(error))") }
        setStatus(LoopStatus(phase: .idle))
        bump()
        return true
    }

    /// 继续只在「已暂停」有效；回到入口（续传 + 对账：暂停期间只改了意图，待办现算）。
    @discardableResult
    public func resume() async -> Bool {
        guard control.paused() else {
            log("resume ignored: not paused")
            return false
        }
        setPausedFlag(false)
        setWait(nil)
        do { try store.appendAudit(audit(AuditKinds.roundControlled, ["action": "continue"])) } catch { log("resume: audit failed (\(error))") }
        bump()
        await trigger(.userContinue)
        return true
    }

    /// 「取消剩余 N 张」弹窗那一刻的边界 + 张数：与计数是**同一个差集**。
    public func remainingSnapshot() async throws -> RemainingSnapshot {
        let targets = try await todoTargets()
        setPending(targets.count)
        return RemainingSnapshot(count: targets.count, takenAtMs: clock(), targets: targets)
    }

    /// X-01：「取消剩余 N 张」，只在「已暂停」与「等待中」有效（X-10：等待中也可用，跟 Android 现行实现）。
    /// 一个事务把 [snapshot] 里的照片写进跳过名单、在途 order 改用户跳过；在飞的那张请桌面丢掉半截；清除暂停 → 空闲。
    /// 返回写进跳过名单的张数；不在允许的状态时返回 nil。
    public func cancelRemaining(_ snapshot: RemainingSnapshot) async throws -> Int? {
        let state = globalState()
        guard state == .paused || state == .waiting else {
            log("cancel ignored: state is \(state.rawValue)")
            return nil
        }
        pendingTriggers.removeAll()
        await cancelAndJoinCycle()
        let boundary = Set(snapshot.targets.map { MediaOrder.key($0.mediaId) })
        let inFlight = try store.currentInStates([.transferring]).filter { boundary.contains(MediaOrder.key($0.mediaId)) }
        let result = try store.cancelRemaining(snapshot.targets, audit: audit(AuditKinds.roundControlled, ["action": "cancel", "skipped": "\(snapshot.count)"]))
        for order in inFlight { await delivery.discardPartial(orderId: order.id, pairingEpoch: order.pairingEpoch) }
        log("cancel: \(result.written) photos skipped (\(result.ordersSkipped) orders, \(result.untouched) settled since the dialog)")
        setPausedFlag(false)
        setWait(nil)
        setStatus(LoopStatus(phase: .idle))
        await refreshPending()
        bump()
        await afterCycle()
        return result.written
    }

    /// 「已跳过的照片 · 点击恢复」：清空跳过名单并把扫描置脏；暂停中只改意图，继续之后接上。返回恢复了几张。
    @discardableResult
    public func restoreSkipped() async throws -> Int {
        let restored = try store.restoreSkipped(audit: audit(AuditKinds.roundControlled, ["action": "restore"]))
        log("restore: \(restored) photos removed from the skip list; the reconcile scan will pick them up")
        bump()
        if restored > 0 && !control.paused() { await trigger(.restoreSkipped) } else { await refreshPending() }
        return restored
    }

    /// 用户点「重试」：当前 FAILED 改回待传输（不受兜底次数上限），然后叫醒循环。
    @discardableResult
    public func retryFailed() async throws -> Int {
        let n = try store.retryFailed(audit: audit(AuditKinds.roundControlled, ["action": "retry"]))
        bump()
        await trigger(.retryFailed)
        return n
    }

    /// 执行时间被系统收回（iOS 的后台时间到期，对位 Android onTimeout）：记原因、停循环、等待中。下一次触发照常再申请。
    public func onLeaseExpired() async {
        control.recordLeaseBlock(.expired)
        log("execution lease expired: stopping the loop; the next trigger may request it again")
        await stopCycle(.executionBlocked)
    }

    /// App 回到前台：一次触发（含对账）。
    public func onAppForeground() async {
        await trigger(.appForeground)
    }

    /// #439：前台心跳确认桌面可达。只在「等待中（桌面不可达 / 桌面不健康且最近一次探测本身就报不健康）」时叫醒循环。
    public func onDesktopReachable() async {
        guard let waiting = control.waitReason() else { return }
        let wake: Bool
        switch waiting {
        case .desktopUnreachable: wake = true
        case .desktopStorageFull, .desktopLibraryUnavailable, .desktopStorageError: wake = waitReasonOf(desktopHealth) != nil
        // iCloud 原图在等的是互联网，不是桌面——连得上桌面证明不了 iCloud 拉得到。
        case .notPaired, .disabled, .wifi, .battery, .executionBlocked, .unexpectedError, .originalUnavailable, .localStorageFull: wake = false
        }
        guard wake else { return }
        log("desktop reachable (foreground heartbeat) while waiting for \(waiting.rawValue): waking the loop")
        await trigger(.desktopReachable)
    }

    /// 网络变化：正在跑且仅 Wi‑Fi 已不满足 → 停循环、登记约束唤醒；否则当作一次触发。
    public func onNetworkChanged() async {
        if cycleActive, waitReasonOf(conditions(), userPresent: false) == .wifi {
            log("network changed: WIFI no longer satisfied, stopping the loop")
            await stopCycle(.wifi)
            return
        }
        await trigger(.networkChange)
    }

    /// C-13：手机此刻没有任何可用网络 → 在飞的这张立即判路径失败。
    public func onNetworkLost() async {
        guard cycleActive else { return }
        log("network lost: path failure for the in-flight item; waiting for the network to come back")
        await stopCycle(.desktopUnreachable)
    }

    public func acknowledgeAudit(_ eventIds: Set<String>) {
        do { try store.acknowledgeAudit(eventIds) } catch { log("acknowledge audit failed (\(error))") }
    }

    public func acknowledgeMissingSource() {
        control.setMissingSourceAckAt(clock())
        bump()
    }

    private func stopCycle(_ reason: WaitReason) async {
        pendingTriggers.removeAll()
        await cancelAndJoinCycle()
        enterWait(reason)
    }

    // MARK: 等待与唤醒

    /// 进入「等待中」后登记唤醒——所有进入等待的路径都只经过这里，唤醒种类只由 [wakePlanOf] 决定。
    private func registerWake(_ reason: WaitReason) {
        switch wakePlanOf(reason) {
        case .awaitsUser:
            log("waiting for \(reason.rawValue): needs the user, no wake registered")
        case let .whenConditionsMet(r):
            scheduler.scheduleWhenConditionsMet(r)
        case .retryProbes:
            if control.retryLadderSpent() {
                // #762：这次故障已经排过一组，不再加排——否则「开始传之后才出错」会每轮重排、无界循环。
                log("waiting for \(reason.rawValue): retry probes already used for this outage")
            } else {
                scheduler.scheduleUnreachableProbes()
                control.setRetryLadderSpent(true)
                log("waiting for \(reason.rawValue): retry probes registered (4 probes after 10/20/40/80 min)")
            }
        }
    }

    /// #762：成功了——这次故障结束：清掉「退避已用」，撤掉还没跑的探测。
    private func recovered(_ why: String) {
        guard control.retryLadderSpent() else { return }
        control.setRetryLadderSpent(false)
        scheduler.cancelUnreachableProbes()
        log("recovered (\(why)): retry probes reset and the remaining ones cancelled")
    }

    private func enterWait(_ reason: WaitReason) {
        setStatus(LoopStatus(phase: .idle, waitReason: reason))
        setWait(reason)
        registerWake(reason)
    }

    /// 一轮的检查 / 传输结束。[wait] 非 nil = 进「等待中」。
    private func settle(_ wait: WaitReason?) {
        if let wait {
            enterWait(wait)
        } else {
            setStatus(LoopStatus(phase: .idle))
            setWait(nil)
        }
    }

    // MARK: 一轮

    private func drain() async {
        while true {
            while !pendingTriggers.isEmpty {
                let reasons = pendingTriggers
                pendingTriggers.removeAll()
                do {
                    try await runCycle(reasons)
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    // 一轮失败（例如本地数据库写入抛错）不能让引擎死掉：进「等待中」（原因可见）并按退避登记唤醒。
                    log("cycle \(reasons.map(\.rawValue)) failed: \(type(of: error)): \(error)")
                    settle(.unexpectedError)
                }
            }
            if status.phase != .idle { setStatus(LoopStatus(phase: .idle, waitReason: status.waitReason)) }
            // 对位 withContext(NonCancellable)：非结构化 Task 不继承取消。
            await Task { await self.refreshPending(); await self.afterCycle() }.value
            // 收尾期间（afterCycle 是一次走网络的审计冲刷，可能几秒）到达的触发被合并进了队列——这里不接住就丢了。
            // Android 的 drain 有同一个窗口（更窄），已另行挂号。
            if pendingTriggers.isEmpty || Task.isCancelled { break }
            log("triggers \(pendingTriggers.map(\.rawValue)) arrived while the cycle was finishing; running again")
        }
        cycleActive = false
        cycleTask = nil
    }

    private func runCycle(_ reasons: [TriggerReason]) async throws {
        let userPresent = reasons.contains { $0.userPresent }
        let reconcile = reasons.contains { $0.reconcile }
        let names = reasons.map(\.rawValue)
        setStatus(LoopStatus(phase: .checking))
        if control.paused() { return settle(nil) }
        guard pairingEpoch() != nil else { return settle(.notPaired) }

        // ---- 入口：不持有执行租约，只读元数据 ----
        try await prepareCursors(reconcile: reconcile)
        if reconcile { await reconcileSourcePresence() }
        let todo = try await countTodo()
        try Task.checkCancellation()
        setPending(todo)
        if todo == 0, try store.scanState().dirty {
            // 扫描脏时计数就是全量差集：一张待办都没有 = 扫描也取不到东西，在入口就收掉，不为它申请租约。
            try store.finishScan()
            log("cycle \(names): reconcile scan has nothing to do (full diff is empty); cleared before the lease")
        }
        if let reason = waitReasonOf(conditions(), userPresent: userPresent) {
            log("cycle \(names): waiting for \(reason.rawValue) (no lease requested)")
            return settle(reason)
        }
        let transferWork = try await hasWork(reconcile: reconcile, askPresence: reasons.contains(.periodic))
        guard transferWork else {
            log("cycle \(names): nothing to transfer")
            recovered("nothing left to transfer")
            return settle(nil)
        }
        let reach = await probe.probe()
        try Task.checkCancellation()
        switch reach {
        case .unreachable:
            log("cycle \(names): desktop unreachable, scheduling probes; no lease, no attempt counted")
            return settle(.desktopUnreachable)
        case .pairingLost:
            return settle(.notPaired)
        case let .reachable(advertised, health, _):
            if let advertised, !advertised.isBlank, advertised != pairingEpoch() { onEpochAdvertised(advertised) }
            desktopHealth = health
            publish()
            // 契约 §7：桌面不健康 → 不申请租约，等待中（具体原因）。
            if let unhealthy = waitReasonOf(health) {
                log("cycle \(names): desktop unhealthy; waiting for \(unhealthy.rawValue)")
                return settle(unhealthy)
            }
        }

        // ---- 申请执行租约：整轮只申请这一次（C-06）；被拒就等下一次触发 ----
        guard await lease.acquire() else {
            control.recordLeaseBlock(.refused)
            log("cycle \(names): execution lease refused: waiting; the next trigger requests it again")
            return settle(.executionBlocked)
        }
        control.clearLeaseBlock()
        try Task.checkCancellation()
        setStatus(LoopStatus(phase: .running))
        setWait(nil)
        doneThisRound = 0
        // AUDIT-07：租约到手 = 这一轮真的开始跑。先给这一轮一个身份并落库，再开跑。
        let roundId = UUID().uuidString.lowercased()
        try store.openRound(roundId)
        roundOutcomes = [:]
        log("cycle \(names): round \(roundId) open")
        let round = Round(reconcile: reconcile, userPresent: userPresent)
        let result: Result<WaitReason?, Error>
        do {
            result = .success(try await delivery.session { try await self.loop(round) })
        } catch {
            result = .failure(error)
        }
        // ---- 收尾（不论正常结束、被取消还是抛错）----
        lease.release()
        closeRound(roundId)
        bump()
        let exit = (try? result.get()) ?? nil
        if !control.paused() { settle(exit) } else { setStatus(LoopStatus(phase: .idle)) }
        let _ = try result.get()
        if exit == nil && !control.paused() { recovered("round finished") }
    }

    /// AUDIT-07：关掉这一轮。一轮一张都没碰过就不发终态（没有对象、没有证据，不构成一次备份操作）。
    private func closeRound(_ roundId: String) {
        let counts = roundOutcomes.mapValues { "\($0)" }
        roundOutcomes = [:]
        do { try store.closeRound(counts.isEmpty ? nil : finishedAudit(roundId, counts)) } catch { log("round \(roundId): close failed (\(error))") }
    }

    /// 入口：游标就位。G 缺失（新装、换桌面清库）或照片库身份变了 → G 从当前位置起步、扫描置脏。只读元数据。
    ///
    /// #904：G 不精确（媒体源说不出 G 是不是还指着这个库——PHPersistentChangeToken 跨图库可能静默错位）时，
    /// **每个对账轮都把扫描置脏**：G 以下漏掉的照片由扫描按 id 找回、按内容哈希判重收敛。
    /// 对位 Android `prepareCursors` 里的 `if (reconcile && !media.preciseGeneration) store.markScanDirty()`（API < 30）。
    private func prepareCursors(reconcile: Bool) async throws {
        let identity = try await media.libraryIdentity()
        try Task.checkCancellation()
        let state = try store.discoveryState()
        if state == nil || (identity != nil && state?.libraryIdentity != identity) {
            try await resetDiscovery(state == nil ? "no cursor yet" : "photo library identity changed", identity: identity)
        }
        if reconcile && !media.preciseDiscovery {
            try store.markScanDirty()
            log("discovery: G may be misplaced (not precise); reconcile round marks the scan dirty")
        }
    }

    /// G 重置到当前位置、扫描置脏：已有的照片交给扫描（按 id），新照片仍然按 G（F3 的 3105 兜底走同一条路）。
    private func resetDiscovery(_ why: String, identity: String?? = .none) async throws {
        let position = try await media.currentPosition()
        try Task.checkCancellation()
        let id: String?
        switch identity {
        case .none: id = try store.discoveryState()?.libraryIdentity
        case let .some(explicit): id = explicit
        }
        try store.saveDiscoveryState(DiscoveryState(position: position, libraryIdentity: id))
        try store.markScanDirty()
        log("discovery: \(why); G reset to the current position, reconcile scan marked dirty")
    }

    /// 入口：这一轮有没有可能取到东西（不读文件、不走网络）。只为「问桌面还在吗」而申请租约只在兜底轮（[askPresence]）。
    private func hasWork(reconcile: Bool, askPresence: Bool) async throws -> Bool {
        // 传输中不看范围（在飞时相册被移出范围的那一行还要改待传输 + 丢弃半截）；待传输只算范围内的。
        if try !store.currentInStates([.transferring], afterId: 0, limit: 1).isEmpty { return true }
        if try store.currentInStates([.pending]).contains(where: { inScope($0.bucketId) }) { return true }
        if try store.scanState().dirty { return true }
        switch try await discoveryStep() {
        case .item: return true
        case .reset: return true
        case .none: break
        }
        if !reconcile { return false }
        if try store.currentInStates([.failed]).contains(where: { $0.attempts < OrderStoreLimits.maxFailures && inScope($0.bucketId) }) { return true }
        return try askPresence && !store.confirmedWithHashAfter(0, limit: 1).isEmpty
    }

    /// 一轮之内的取件状态。
    private final class Round: @unchecked Sendable {
        let reconcile: Bool
        let userPresent: Bool
        var legacyAfter: Int64 = 0
        var retryAfter: Int64 = 0
        var presenceDone: Bool
        var handled = Set<Int64>()

        init(reconcile: Bool, userPresent: Bool) {
            self.reconcile = reconcile
            self.userPresent = userPresent
            presenceDone = !reconcile
        }
    }

    /// 逐张循环本体。返回退出原因（nil = 取不到下一张，正常结束）。
    private func loop(_ round: Round) async throws -> WaitReason? {
        while true {
            try Task.checkCancellation()
            // C-07：每张开始前重检条件，并确认租约仍然有效。
            if control.paused() { return nil }
            if let reason = waitReasonOf(conditions(), userPresent: round.userPresent) { return reason }
            if !lease.isHeld() { return .executionBlocked }
            guard let epoch = pairingEpoch() else { return .notPaired }
            guard let item = try await pickNext(round) else { return nil }
            if case let .existing(order, _) = item, !round.handled.insert(order.id).inserted {
                log("order \(order.id) picked twice in one round; stopping to avoid a spin")
                return nil
            }
            switch try await process(item, epoch: epoch) {
            case .next: break
            case let .exit(reason): return reason
            }
            lease.renew()
        }
    }

    // MARK: 取件

    /// 这一张从哪个来源取的：决定提交时推进哪个游标。
    private enum Origin { case legacy, scan, discovery, retry }

    private enum WorkItem {
        case existing(Order, Origin)
        case fresh(MediaSnapshot, Origin)
    }

    private enum StepResult {
        case next
        case exit(WaitReason)
    }

    private enum DiscoveryStep {
        case item(WorkItem)
        /// 游标失效、已重置并把扫描置脏：回到取件开头让扫描来取。
        case reset
        case none
    }

    /// 取件固定优先级：遗留续传 → 对账扫描 → 新照片 → 对账补传（待传输 / 失败重试 / 桌面缺失）。
    private func pickNext(_ round: Round) async throws -> WorkItem? {
        while true {
            if let order = try store.currentInStates([.transferring], afterId: round.legacyAfter, limit: 1).first {
                round.legacyAfter = order.id
                return .existing(order, .legacy)
            }
            if let item = try await scanStep() { return item }
            switch try await discoveryStep() {
            case let .item(item): return item
            case .reset: continue
            case .none: break
            }
            let states: Set<OrderState> = round.reconcile ? [.pending, .failed] : [.pending]
            let batch = try store.currentInStates(states, afterId: round.retryAfter, limit: Self.retryBatch)
            for order in batch {
                round.retryAfter = order.id
                if order.state == .failed && order.attempts >= OrderStoreLimits.maxFailures { continue }
                // 范围是查询条件：相册被移出范围的待传输 / 失败行不取（相册加回来再取）。
                if !inScope(order.bucketId) { continue }
                return .existing(order, .retry)
            }
            if !batch.isEmpty { continue }
            if !round.presenceDone {
                round.presenceDone = true
                if try await runRemotePresence() > 0 { continue }
            }
            return nil
        }
    }

    /// 这张照片要不要由扫描 / 发现来源建一行新 order：不在跳过名单里，且当前行不是同版本的「已有结局」或「还在路上」。
    private func needsNewOrder(_ s: MediaSnapshot) throws -> Bool {
        if try store.isSkipped(s.mediaId) { return false }
        guard let current = try store.currentForMedia(s.mediaId) else { return true }
        if current.sourceVersion != s.sourceVersion { return true }
        return current.state == .skippedByUser
    }

    /// 对账扫描（脏时才是来源）：按 id 从 S 往后，跳过的照片批量推进 S；扫到末尾清脏。
    private func scanStep() async throws -> WorkItem? {
        while true {
            let scan = try store.scanState()
            guard scan.dirty else { return nil }
            let batch = try await media.inScope(after: scan.cursor, limit: Self.sourceBatch)
            try Task.checkCancellation()
            if batch.isEmpty {
                try store.finishScan()
                log("reconcile scan finished")
                return nil
            }
            var skippedTo: String?
            for s in batch {
                if try needsNewOrder(s) {
                    if let k = skippedTo { try store.advanceScan(k) }
                    return .fresh(s, .scan)
                }
                skippedTo = s.mediaId
            }
            if let k = skippedTo { try store.advanceScan(k) }
        }
    }

    /// 发现：按 G 取新照片（D-01：按媒体源的顺序、不插队），不需要动作的批量推进 G。
    ///
    /// iOS 变体：G 是不透明位置，推进是覆盖写（SQL 里取不了 max）。单调性由这里保证——G 只沿 `changes` 的返回顺序前进：
    /// 跳过的推进到最后一张跳过的位置；需要动作的那张在结局落库时才推进到它自己的位置（它是 skippedTo 之后的第一张）。
    private func discoveryStep() async throws -> DiscoveryStep {
        guard var after = try store.discoveryState()?.position else { return .none }
        while true {
            let batch: [MediaSnapshot]
            do {
                batch = try await media.changes(after: after, limit: Self.sourceBatch)
            } catch is DiscoveryCursorExpired {
                try await resetDiscovery("discovery cursor expired (3105)")
                return .reset
            }
            try Task.checkCancellation()
            if batch.isEmpty { return .none }
            var skippedTo: DiscoveryPosition?
            for s in batch {
                if try needsNewOrder(s) {
                    if let p = skippedTo { try store.advanceDiscovery(p) }
                    return .item(.fresh(s, .discovery))
                }
                skippedTo = s.position
            }
            guard let p = skippedTo, p != after else { return .none }
            try store.advanceDiscovery(p)
            after = p
        }
    }

    // MARK: 准备 → 传输 → 提交

    /// 提交时推进哪个游标：只有新照片推进 G，扫描只推进 S，已有 order 什么都不推进（O-12）。
    private struct Progress {
        var advance: DiscoveryPosition?
        var scanTo: String?
    }

    private func progressOf(_ s: MediaSnapshot, _ origin: Origin) -> Progress {
        switch origin {
        case .discovery: return Progress(advance: s.position, scanTo: nil)
        case .scan: return Progress(advance: nil, scanTo: s.mediaId)
        case .legacy, .retry: return Progress()
        }
    }

    private func write(_ p: Progress) throws {
        if let a = p.advance { try store.advanceDiscovery(a) }
        if let s = p.scanTo { try store.advanceScan(s) }
    }

    private func process(_ item: WorkItem, epoch: String) async throws -> StepResult {
        switch item {
        case let .existing(order, _): return try await processExisting(order, epoch: epoch)
        case let .fresh(snapshot, origin): return try await processFresh(snapshot, origin, epoch: epoch)
        }
    }

    /// 导入（准备这一步唯一读文件的地方），单张失败当场重试 1 次。结果 nil 表示两次都抛了，第二项是原因。
    private func importWithRetry(_ details: MediaDetails) async throws -> (ImportResult?, String) {
        var reason = "import"
        for attempt in 0..<2 {
            do {
                let result = try await importer.importMedia(details)
                if Task.isCancelled {
                    // 导入完成时这一轮已被取消：这份导入不会再被用到，当场放掉。
                    if case let .imported(hash, _) = result { importer.release(hash) }
                    throw CancellationError()
                }
                return (result, reason)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                reason = "import:\(type(of: error))"
                log("media \(details.snapshot.mediaId): import failed (\(error))\(attempt == 0 ? "; retrying once" : "")")
            }
        }
        return (nil, reason)
    }

    private func processFresh(_ snapshot: MediaSnapshot, _ origin: Origin, epoch: String) async throws -> StepResult {
        let progress = progressOf(snapshot, origin)
        let details = try await media.lookup(snapshot.mediaId)
        try Task.checkCancellation()
        guard let details, inScope(details.snapshot.bucketId) else {
            try write(progress)
            return .next
        }
        let version = details.snapshot.sourceVersion
        let bucket = details.snapshot.bucketId
        let (imported, failure) = try await importWithRetry(details)
        switch imported {
        case nil:
            // 读不出来（两次）：记一次失败（有上限），游标照常推进，不在这张上打转。
            let row = try store.insert(NewOrder(mediaId: snapshot.mediaId, sourceVersion: version, bucketId: bucket, contentHash: nil, state: .transferring, pairingEpoch: epoch))
            try fail(row, progress, failure)
            return .next
        case .sourceMissing:
            // 照片库还列着、文件读不到：记「源已删」（同版本即结局，不再算待办），游标推进。
            let record = itemAudit(AuditKinds.itemSourceMissing, snapshot.mediaId, ["mediaId": snapshot.mediaId])
            try store.insert(
                NewOrder(mediaId: snapshot.mediaId, sourceVersion: version, bucketId: bucket, contentHash: nil, state: .skippedSourceMissing, pairingEpoch: epoch),
                advance: progress.advance, scanTo: progress.scanTo, audit: record
            )
            countOutcome(record)
            onSettled()
            bump()
            return .next
        case let .originalUnavailable(reason):
            // #311 D4：iCloud 原图因网络拉不下来——不建行、不推进游标、不计失败；退出循环等网络（下一轮从同一张重来）。
            log("media \(snapshot.mediaId): original not available (\(reason)); waiting, nothing counted")
            return .exit(.originalUnavailable)
        case let .localStorageFull(reason):
            // #911：手机空间不足——同 D4 的处置：不建行、不推进游标、不计失败，整体等待。
            log("media \(snapshot.mediaId): phone storage full (\(reason)); waiting, nothing counted")
            return .exit(.localStorageFull)
        case let .imported(hash, _):
            // 导入算出 hash → 建 order（传输中，带 hash）→ 传输。G / S 在结局落库时一起推进（#415 裁决 8）。
            // #775：导入一拿到手就进作用域——建 order 本身也可能失败。
            return try await releasingOnAbort(hash) {
                let row = try self.store.insert(NewOrder(mediaId: snapshot.mediaId, sourceVersion: version, bucketId: bucket, contentHash: hash, state: .transferring, pairingEpoch: epoch))
                self.bump()
                return try await self.deliverAndCommit(row, hash: hash, details: details, progress: progress, epoch: epoch)
            }
        }
    }

    /// 已有 order（遗留续传 / 对账补传）：开始前按原图、版本、范围重检；重新导入拿 hash 与行里记的比对，
    /// 通过后置为传输中。已有 order 提交时**不推进任何游标**。
    private func processExisting(_ order: Order, epoch: String) async throws -> StepResult {
        let transferring = order.state == .transferring
        let details = try await media.lookup(order.mediaId)
        try Task.checkCancellation()
        guard let details, details.snapshot.sourceVersion == order.sourceVersion else {
            // 原图没了；或中断期间被编辑成了新版本——这一行描述的版本已不存在，新版本由扫描 / 发现另起一行。
            try await settleSourceMissing(order, reason: details == nil ? "gone" : "version_changed", discard: transferring)
            return .next
        }
        if !inScope(details.snapshot.bucketId) {
            // 在途的这张所在相册被移出范围：不续传，丢弃半截；它从待办里消失（范围是查询条件）。
            if transferring, try store.transition(order.id, expected: [.transferring], to: .pending) {
                await delivery.discardPartial(orderId: order.id, pairingEpoch: epoch)
                bump()
            }
            return .next
        }
        let (imported, failure) = try await importWithRetry(details)
        switch imported {
        case nil:
            if try store.transition(order.id, expected: OrderState.open, to: .transferring) { try fail(order, Progress(), failure) }
            return .next
        case .sourceMissing:
            try await settleSourceMissing(order, reason: "gone", discard: transferring)
            return .next
        case let .originalUnavailable(reason):
            log("order \(order.id): original not available (\(reason)); leaving the row as it is, nothing counted")
            return .exit(.originalUnavailable)
        case let .localStorageFull(reason):
            log("order \(order.id): phone storage full (\(reason)); leaving the row as it is, nothing counted")
            return .exit(.localStorageFull)
        case let .imported(hash, _):
            return try await releasingOnAbort(hash) {
                if let recorded = order.contentHash, recorded != hash {
                    // 同一版本读出了另一份字节（中断期间被原地改写、版本没跟上）：这一行的 lease 描述的那份内容已不存在——
                    // 源已删 + cancel_tuple；**现在的字节另起一行传**（不另起的话版本没变，扫描不再建行，这张就漏传了）。
                    guard try await self.settleSourceMissing(order, reason: "content_changed", discard: true) else {
                        self.importer.release(hash)
                        return .next
                    }
                    let row = try self.store.insert(NewOrder(mediaId: order.mediaId, sourceVersion: order.sourceVersion, bucketId: order.bucketId, contentHash: hash, state: .transferring, pairingEpoch: epoch))
                    self.bump()
                    return try await self.deliverAndCommit(row, hash: hash, details: details, progress: Progress(), epoch: epoch)
                }
                guard try self.store.transition(order.id, expected: OrderState.open, to: .transferring, contentHash: hash), var row = try self.store.get(order.id) else {
                    self.importer.release(hash)
                    return .next
                }
                row.contentHash = hash
                return try await self.deliverAndCommit(row, hash: hash, details: details, progress: Progress(), epoch: epoch)
            }
        }
    }

    /// 一次导入是一份资源：[body] 正常返回 = 它对每种结局作了交代；**异常退出一律放掉**（取消与失败是同一件事：这条路走不完了）。
    private func releasingOnAbort<T>(_ hash: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            importer.release(hash)
            throw error
        }
    }

    /// 返回这一行是否由本次结掉（不在 OPEN 状态里的行不动）。
    @discardableResult
    private func settleSourceMissing(_ order: Order, reason: String, discard: Bool) async throws -> Bool {
        let record = itemAudit(AuditKinds.itemSourceMissing, order.mediaId, ["queueSequence": "\(order.id)", "reason": reason])
        let settled = try store.transition(order.id, expected: OrderState.open, to: .skippedSourceMissing, countAttempt: false, contentHash: nil, advance: nil, scanTo: nil, audit: record)
        if settled {
            countOutcome(record)
            if discard { await delivery.discardPartial(orderId: order.id, pairingEpoch: order.pairingEpoch) }
            bump()
        }
        return settled
    }

    private func deliverAndCommit(_ order: Order, hash: String, details: MediaDetails, progress: Progress, epoch: String) async throws -> StepResult {
        let request = DeliveryRequest(orderId: order.id, pairingEpoch: epoch, contentHash: hash, details: details)
        setStatus(LoopStatus(phase: .running, current: CurrentItem(orderId: order.id, fileName: details.fileName, bytesSent: 0, totalBytes: details.sizeBytes)))
        var outcome = try await deliverOnce(request)
        if case let .itemFailure(reason) = outcome {
            // C-09：单张失败立即重试 1 次。
            log("order \(order.id): item failure (\(reason)); retrying once")
            outcome = try await deliverOnce(request)
        }
        switch outcome {
        case let .confirmed(receipt):
            let valid = receipt.queueSequence == order.id && receipt.pairingEpoch == epoch && (receipt.contentHash == nil || receipt.contentHash == hash)
            if !valid {
                log("order \(order.id): receipt does not match the request; treating as item failure")
                try fail(order, progress, "receipt_mismatch")
            } else {
                // E-01 / O-07：CONFIRMED、hash 映射（行本身）、游标推进、确认审计——同一次写入。
                let record = itemAudit(AuditKinds.itemConfirmed, order.mediaId, [
                    "queueSequence": "\(order.id)", "sourceVersion": order.sourceVersion, "contentHash": hash, "receiptRef": receipt.receiptId,
                ])
                if try store.transition(order.id, expected: [.transferring], to: .confirmed, countAttempt: false, contentHash: nil, advance: progress.advance, scanTo: progress.scanTo, audit: record) {
                    countOutcome(record)
                    doneThisRound += 1
                    onSettled()
                    recovered("a photo was confirmed")
                }
            }
            bump()
            return .next
        case .sourceMissing:
            // 原图在供数期间被删 / 被改：源已删，不计失败；丢弃桌面半截、放掉导入。
            importer.release(hash)
            let record = itemAudit(AuditKinds.itemSourceMissing, order.mediaId, ["queueSequence": "\(order.id)"])
            if try store.transition(order.id, expected: [.transferring], to: .skippedSourceMissing, countAttempt: false, contentHash: nil, advance: progress.advance, scanTo: progress.scanTo, audit: record) {
                countOutcome(record)
                await delivery.discardPartial(orderId: order.id, pairingEpoch: epoch)
                onSettled()
            }
            bump()
            return .next
        case let .itemFailure(reason):
            importer.release(hash)
            try fail(order, progress, reason)
            return .next
        case let .pathFailure(reason):
            // C-05 / C-10：路径失败——order 保持「传输中」可续传，不计次数，退出循环、登记探测。
            log("order \(order.id): path failure (\(reason)); leaving it resumable")
            return .exit(.desktopUnreachable)
        case let .peerFailure(kind, code):
            // 契约 §5：对端失败——退出循环，不计次数，原因带回手机显示。
            log("order \(order.id): desktop cannot store it (\(kind.rawValue)/\(code)); waiting for the next wake")
            return .exit(waitReasonOf(kind))
        case .pairingLost:
            return .exit(.notPaired)
        }
    }

    private func deliverOnce(_ request: DeliveryRequest) async throws -> DeliveryOutcome {
        let lease = self.lease
        do {
            let outcome = try await delivery.deliver(request) { [weak self] bytes in
                lease.renew()
                Task { await self?.progressed(request.orderId, bytes) }
            }
            try Task.checkCancellation()
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 端口没分类的异常：保守地当作这一张的问题（计次数、有上限），不当路径失败（那会无限续）。
            return .itemFailure("unclassified: \(type(of: error))")
        }
    }

    private func progressed(_ orderId: Int64, _ bytes: Int64) {
        guard var current = status.current, current.orderId == orderId, bytes > current.bytesSent else { return }
        current.bytesSent = bytes
        var s = status
        s.current = current
        setStatus(s)
    }

    private func fail(_ order: Order, _ progress: Progress, _ reason: String) throws {
        // #418：「一张照片记为 FAILED」的唯一调用点；失败通知故意不在这里发（分类刚落地，多半是会自愈的问题）。
        let record = itemAudit(AuditKinds.itemAttention, order.mediaId, ["reason": reason, "queueSequence": "\(order.id)"])
        if try store.transition(order.id, expected: [.transferring], to: .failed, countAttempt: true, contentHash: nil, advance: progress.advance, scanTo: progress.scanTo, audit: record) {
            countOutcome(record)
        }
        bump()
    }

    /// 这张照片有了结局、离开待办。
    private func onSettled() {
        setPending(pending - 1)
    }

    // MARK: 对账补传：桌面缺失

    /// O-08：分页问桌面「已确认的这些还在吗」。缺的且原图还在、在范围内 → **新建一行**待传输（不复用原 id）；
    /// 原图也没了 → 只记审计 `UNRECOVERABLE`（同一行同一配对代号只记一次）。返回新建了几行。
    private func runRemotePresence() async throws -> Int {
        var after: Int64 = 0
        var requeued = 0
        while true {
            let page = try store.confirmedWithHashAfter(after, limit: Self.presencePage)
            guard let last = page.last else { break }
            let hashes = Array(Set(page.compactMap(\.contentHash))).sorted()
            let missing: Set<String>
            do {
                missing = try await presence.missing(hashes)
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                log("presence probe failed (\(type(of: error))); retrying next reconcile round")
                break
            }
            for order in page {
                guard let hash = order.contentHash, missing.contains(hash), inScope(order.bucketId) else { continue }
                if order.sourceMissing {
                    let epochKey = pairingEpoch() ?? order.pairingEpoch
                    try store.appendAuditOnce("unrecoverable:\(order.id):\(epochKey)", audit(AuditKinds.reconciliationResolved, ["disposition": "UNRECOVERABLE", "contentHash": hash]))
                    continue
                }
                let record = audit(AuditKinds.reconciliationResolved, ["disposition": "REUPLOAD", "contentHash": hash])
                try store.insert(NewOrder(mediaId: order.mediaId, sourceVersion: order.sourceVersion, bucketId: order.bucketId, contentHash: hash, state: .pending, pairingEpoch: order.pairingEpoch), advance: nil, scanTo: nil, audit: record)
                countOutcome(record)
                requeued += 1
            }
            after = last.id
        }
        if requeued > 0 {
            log("presence: desktop is missing \(requeued) confirmed photos; re-uploading")
            setPending(pending + requeued)
        }
        bump()
        return requeued
    }

    // MARK: 对账：原图还在吗（#459）

    private struct SourcePresencePlan {
        let mark: [Int64]
        let clear: [Int64]
    }

    /// #459：对账轮入口（只读元数据、不持有租约）按照片库差集写 `source_missing`。不是完整相册权限 → 整步跳过。
    private func reconcileSourcePresence() async {
        guard mediaAbsenceTrusted() else {
            log("source_missing: media access is not full; absence proves nothing, skipped")
            return
        }
        let plan: SourcePresencePlan?
        do {
            plan = try await sourcePresencePlan()
        } catch {
            log("source_missing: photo library read failed (\(error)); nothing written")
            return
        }
        guard let plan else {
            log("source_missing: the photo library could not confirm which photos are gone; nothing written")
            return
        }
        var marked = 0, cleared = 0
        for id in plan.mark where (try? store.setSourceMissing(id, missing: true, audit: nil)) == true { marked += 1 }
        for id in plan.clear where (try? store.setSourceMissing(id, missing: false, audit: nil)) == true { cleared += 1 }
        log("source_missing: marked \(marked) cleared \(cleared)")
        if marked + cleared > 0 { bump() }
    }

    /// 两路归并：范围内照片（按 id 字节序）× 当前行（按 media_id）；列表里没有的再按 id 回查一次。nil = 读不出来。
    private func sourcePresencePlan() async throws -> SourcePresencePlan? {
        var clear: [Int64] = []
        var unlisted: [Order] = []
        let snapshots = ScopeCursor(media: media, page: Self.countPage)
        let orders = try store.currentOrders().cursor()
        var snap = try await snapshots.next()
        while let order = try orders.next() {
            guard order.state == .confirmed else { continue }
            while let s = snap, MediaOrder.precedes(s.mediaId, order.mediaId) { snap = try await snapshots.next() }
            if let s = snap, MediaOrder.same(s.mediaId, order.mediaId) {
                if order.sourceMissing { clear.append(order.id) }
                continue
            }
            if !inScope(order.bucketId) { continue }
            unlisted.append(order)
        }
        if unlisted.isEmpty { return SourcePresencePlan(mark: [], clear: clear) }
        guard let existing = try await media.existingIds(unlisted.map(\.mediaId)) else { return nil }
        let present = Set(existing.map(MediaOrder.key))
        var mark: [Int64] = []
        for order in unlisted {
            let isPresent = present.contains(MediaOrder.key(order.mediaId))
            if !isPresent && !order.sourceMissing { mark.append(order.id) }
            if isPresent && order.sourceMissing { clear.append(order.id) }
        }
        return SourcePresencePlan(mark: mark, clear: clear)
    }

    // MARK: 待办（现算）

    private func refreshPending() async {
        do {
            setPending(try await countTodo())
        } catch {
            log("pending: count failed (\(error))")
        }
    }

    /// 这张（这个版本）是不是待办：不在跳过名单里，且当前行不是同版本的结局。
    private func isTodo(_ s: MediaSnapshot, _ current: Order?, skipped: Bool) -> Bool {
        if skipped { return false }
        if let c = current, c.sourceVersion == s.sourceVersion, c.state.isSettled { return false }
        return true
    }

    /// 精确的待办张数（只读元数据，**不触发任何 iCloud 下载**）。
    /// - 扫描脏时：全量差集，与 [todoTargets] 同一个函数。
    /// - 不脏时：G 以下没有漏网的，待办只可能是「新照片（G 之后）」或「当前行还在路上」——两部分按 media_id 去重。
    private func countTodo() async throws -> Int {
        if try store.scanState().dirty { return try await todoTargets().count }
        var todo = Set<[UInt8]>()
        if var after = try store.discoveryState()?.position {
            while true {
                let page: [MediaSnapshot]
                do {
                    page = try await media.changes(after: after, limit: Self.countPage)
                } catch is DiscoveryCursorExpired {
                    // 计数不写 G：它会在一轮挂起时被重入（trigger → refreshPending），这里写了，那一轮醒来会用旧位置覆盖回去。
                    // 全量差集本来就精确；重置交给这一轮的 prepareCursors / discoveryStep。
                    return try await todoTargets().count
                }
                for s in page where try isTodo(s, store.currentForMedia(s.mediaId), skipped: store.isSkipped(s.mediaId)) {
                    todo.insert(MediaOrder.key(s.mediaId))
                }
                guard page.count == Self.countPage, let next = page.last?.position, next != after else { break }
                after = next
            }
        }
        for order in try store.currentInStates(OrderState.open) {
            let key = MediaOrder.key(order.mediaId)
            if todo.contains(key) || !inScope(order.bucketId) { continue }
            if try store.isSkipped(order.mediaId) { continue }
            todo.insert(key)
        }
        return todo.count
    }

    /// 全量差集：范围内照片（按 id）× 当前行（按 media_id）× 跳过名单（按 media_id），三路归并，只读元数据。
    private func todoTargets() async throws -> [SkipTarget] {
        var out: [SkipTarget] = []
        let snapshots = ScopeCursor(media: media, page: Self.countPage)
        let orders = try store.currentOrders().cursor()
        let skips = try store.skipList().cursor()
        var order = try orders.next()
        var skip = try skips.next()
        var last: String?
        while let s = try await snapshots.next() {
            // 按 id 升序；万一媒体源给出重复 / 回退的行，跳过而不是抛。
            if let l = last, !MediaOrder.precedes(l, s.mediaId) { continue }
            last = s.mediaId
            while let o = order, MediaOrder.precedes(o.mediaId, s.mediaId) { order = try orders.next() }
            while let k = skip, MediaOrder.precedes(k, s.mediaId) { skip = try skips.next() }
            let current = order.flatMap { MediaOrder.same($0.mediaId, s.mediaId) ? $0 : nil }
            let skipped = skip.map { MediaOrder.same($0, s.mediaId) } ?? false
            if isTodo(s, current, skipped: skipped) {
                out.append(SkipTarget(mediaId: s.mediaId, sourceVersion: s.sourceVersion, bucketId: s.bucketId))
            }
        }
        return out
    }
}

/// 范围内照片的分页游标（按 id 字节序）。
private final class ScopeCursor {
    private let media: MediaSource
    private let pageSize: Int
    private var page: [MediaSnapshot] = []
    private var index = 0
    private var after: String?
    private var exhausted = false

    init(media: MediaSource, page: Int) {
        self.media = media
        pageSize = page
    }

    func next() async throws -> MediaSnapshot? {
        if index >= page.count {
            if exhausted { return nil }
            page = try await media.inScope(after: after, limit: pageSize)
            index = 0
            if page.count < pageSize { exhausted = true }
            guard let tail = page.last else { return nil }
            after = tail.mediaId
        }
        let s = page[index]
        index += 1
        return s
    }
}
