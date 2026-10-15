// #340：iOS 的执行租约（Android FGS + wakelock 的对位）与一次后台任务的跑法。
//
// iOS 上能让循环跑的「执行时间」有四种来源：App 在前台；`beginBackgroundTask` 给的收尾时间（刚退到后台的几十秒）；
// 系统按 BGProcessingTask 给的窗口（长任务）；BGAppRefreshTask 给的窗口（短任务，#958：20 秒自收尾、只传照片）。
// [ExecutionWindow] 把它们合成一个租约：任一个开着就算持有。
// 窗口全部关掉（App 退后台且收尾时间用完、后台任务到期）时，App 层调 `engine.onLeaseExpired()`——引擎停循环、
// 传输端口有界地发 `flow.suspend`、在飞的那张保持传输中、等待中（EXECUTION_BLOCKED）。
import Foundation

public final class ExecutionWindow: ExecutionLease, @unchecked Sendable {
    private let lock = NSLock()
    private var appActive = false
    private var finishingTime = false
    private var backgroundTask = false
    private var shortTask = false
    private var acquired = false
    private var lastStatus = LoopStatus()

    public init() {}

    private func open() -> Bool { appActive || finishingTime || backgroundTask || shortTask }

    /// App 的 scenePhase 变化（.active = true；.background / .inactive = false）。
    public func setAppActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        appActive = active
    }

    /// `UIApplication.beginBackgroundTask` 给的收尾时间开始 / 结束。
    public func setFinishingTime(_ open: Bool) {
        lock.lock(); defer { lock.unlock() }
        finishingTime = open
    }

    /// 系统给的 BGProcessingTask 窗口开始 / 结束。
    public func setBackgroundTask(_ open: Bool) {
        lock.lock(); defer { lock.unlock() }
        backgroundTask = open
    }

    /// 系统给的 BGAppRefreshTask 窗口（短任务）开始 / 结束。
    public func setShortTask(_ open: Bool) {
        lock.lock(); defer { lock.unlock() }
        shortTask = open
    }

    /// 只有短任务窗口开着、其他三种都没开：引擎不处理视频。
    public var photosOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return shortTask && !(appActive || finishingTime || backgroundTask)
    }

    /// 是否有任何执行时间（给 App 层判断「退后台时要不要申请收尾时间」）。
    public var hasExecutionTime: Bool {
        lock.lock(); defer { lock.unlock() }
        return open()
    }

    /// 这一轮是否持有租约（循环在跑）。
    public var isAcquired: Bool {
        lock.lock(); defer { lock.unlock() }
        return acquired
    }

    public var status: LoopStatus {
        lock.lock(); defer { lock.unlock() }
        return lastStatus
    }

    public func acquire() async -> Bool { acquireNow() }

    private func acquireNow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        acquired = open()
        return acquired
    }

    public func isHeld() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acquired && open()
    }

    public func renew() {}

    public func update(_ status: LoopStatus) {
        lock.lock(); defer { lock.unlock() }
        lastStatus = status
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        acquired = false
    }
}

/// 一次后台任务（BGProcessingTask）怎么跑。薄层在 launch handler 里调 [run]，在 expirationHandler 里调 [expire]。
public enum BackgroundRun {
    /// 打开执行窗口 → 用请求里记的原因叫醒引擎 → 等这一轮跑完 → 关窗口 → 计划往前走并重新挂。返回给系统的 success。
    public static func run(engine: FlowEngine, window: ExecutionWindow, scheduler: PlannedWakeScheduler, reason: TriggerReason) async -> Bool {
        window.setBackgroundTask(true)
        await engine.trigger(reason)
        await engine.awaitIdle()
        window.setBackgroundTask(false)
        scheduler.didRun(reason)
        let view = await engine.view
        // 「成功」= 这一轮没被系统打断：跑完了、或者在等一个我们自己判定的条件（都不需要系统立刻重试）。
        return view.waitReason != .executionBlocked
    }

    /// 短任务的跑法（#958）：打开短任务窗口 → 触发一轮 → 并行一个 [budget] 计时，到点走与 [expire] 相同的收尾 → 等这一轮结束 → 关窗口。
    /// 调用时若其他窗口已开着（前台 / 宽限期 / 长任务），已有人在跑，直接返回 true 不重复跑。
    /// 返回给系统的 success：恒为 true（收尾是我们自己定的，不需要系统重试）。
    public static func runShort(
        engine: FlowEngine, window: ExecutionWindow, logger: CoreLogger = NoopLogger(),
        budget: TimeInterval = 20, reason: TriggerReason = .periodic
    ) async -> Bool {
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        if window.hasExecutionTime {
            logger.log("short task: another window is open; nothing to do (finish=other_window elapsedMs=\(ms()))")
            return true
        }
        logger.log("short task: woken (budget \(Int(budget))s)")
        window.setShortTask(true)
        let timedOut = TimeoutFlag()
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000)) } catch { return }
            timedOut.set()
            logger.log("short task: budget reached; finishing")
            await expireShort(engine: engine, window: window)
        }
        await engine.trigger(reason)
        await engine.awaitIdle()
        timer.cancel()
        window.setShortTask(false)
        logger.log("short task: finished (finish=\(timedOut.isSet ? "budget" : "done") elapsedMs=\(ms()))")
        return true
    }

    /// 长任务（BGProcessingTask）到期：只关长任务自己这一个来源；关完之后若没有任何窗口还开着，才让引擎按「执行时间被收回」停下
    /// （在飞的那张保持传输中）。前台 / 宽限期 / 短任务还开着，租约仍然持有，这一轮继续。
    public static func expire(engine: FlowEngine, window: ExecutionWindow) async {
        window.setBackgroundTask(false)
        if !window.hasExecutionTime { await engine.onLeaseExpired() }
    }

    /// 短任务（BGAppRefreshTask）到期 / 20 秒到点：规则同 [expire]，只关短任务自己。
    public static func expireShort(engine: FlowEngine, window: ExecutionWindow) async {
        window.setShortTask(false)
        if !window.hasExecutionTime { await engine.onLeaseExpired() }
    }

    /// 宽限期（beginBackgroundTask）到期：规则同 [expire]，只关宽限期自己。
    public static func expireFinishingTime(engine: FlowEngine, window: ExecutionWindow) async {
        window.setFinishingTime(false)
        if !window.hasExecutionTime { await engine.onLeaseExpired() }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
