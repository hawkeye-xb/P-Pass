// #340：iOS 的执行租约（Android FGS + wakelock 的对位）与一次后台任务的跑法。
//
// iOS 上能让循环跑的「执行时间」有四种来源：App 在前台；`beginBackgroundTask` 给的收尾时间（刚退到后台的几十秒）；
// 系统按 BGProcessingTask 给的窗口（长任务）；BGAppRefreshTask 给的窗口（短任务，#958：20 秒自收尾、只传照片）。
// [ExecutionWindow] 把它们合成一个租约：任一个开着就算持有。
// 任一窗口到期，App 层只关它自己并调 `engine.onLeaseExpired()`；引擎按此刻的租约定停不停（#1007）——窗口全部关掉
// （App 退后台且收尾时间用完、后台任务到期）才停循环、传输端口有界地发 `flow.suspend`、在飞的那张保持传输中、等待中（EXECUTION_BLOCKED）。
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

    /// App 现在是否在前台（scenePhase == .active）。给「只在人在场时才做」的触发用（相册变化 → FOREGROUND_MEDIA_CHANGE，#978）。
    public var isAppActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return appActive
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

    /// 除短任务外还开着哪些窗口（只给日志用，如 `[finishing]`）。
    public var openSourcesExceptShort: [String] {
        lock.lock(); defer { lock.unlock() }
        return [appActive ? "foreground" : nil, finishingTime ? "finishing" : nil, backgroundTask ? "long" : nil].compactMap { $0 }
    }

    /// 只有短任务窗口开着、其他三种都没开：引擎不处理视频。
    public var photosOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return shortTask && !(appActive || finishingTime || backgroundTask)
    }

    /// 是否有任何执行时间（[ExecutionLease.hasExecutionTime]：引擎收到到期信号时重读）。
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

    /// 短任务的跑法（#958）：打开短任务窗口 → 触发一轮 → 并行一个 [budget] 计时。窗口取并集：其他窗口已开着也照常叠加
    /// （引擎在跑时会合并触发；photosOnly 按当前开着的窗口实时算；到期只关自己）。
    /// 结束条件是「这一轮结束」或「计时到点」，先到的那个：到点走 [expireShort]（只关短任务窗口；别的窗口还开着，这一轮不停），
    /// 然后就返回，不等前台 / 宽限期启动的那一轮跑完。系统任务的完成由调用方只调一次。
    /// 返回给系统的 success：恒为 true（收尾是我们自己定的，不需要系统重试）。
    /// 触发原因默认 [.mediaChange]（对齐 Android 拍照后的 MediaWatchJob）：只做增量发现（沿 G 游标 / PHPersistentChangeToken），
    /// 不做全量对账（不查源文件在不在、不置脏扫描、不问桌面）——那一步真机上 0 张待传也要约 3.6 秒，而预算只有 20 秒；
    /// 全量对账留给长任务和前台。不算人在场，后台开关与电量检查照常。
    public static func runShort(
        engine: FlowEngine, window: ExecutionWindow, logger: CoreLogger = NoopLogger(),
        budget: TimeInterval = 20, reason: TriggerReason = .mediaChange
    ) async -> Bool {
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        logger.log("short task: woken (budget \(Int(budget))s, others=\(window.openSourcesExceptShort))")
        window.setShortTask(true)
        let budgetReached = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            let timer = Task {
                do { try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000)) } catch { return }
                logger.log("short task: budget reached; finishing")
                await expireShort(engine: engine, window: window)
                once.resume(true)
            }
            Task {
                await engine.trigger(reason)
                await engine.awaitIdle()
                timer.cancel()
                once.resume(false)
            }
        }
        window.setShortTask(false)
        logger.log("short task: finished (finish=\(budgetReached ? "budget" : "done") elapsedMs=\(ms()))")
        return true
    }

    /// 长任务（BGProcessingTask）到期：只关长任务自己这一个来源，然后告诉引擎。停不停由引擎按此刻的租约定（#1007）：
    /// 没有任何窗口还开着才停（在飞的那张保持传输中）；前台 / 宽限期 / 短任务还开着，这一轮继续。
    /// 这里不先判断再通知——判断和引擎动手之间隔着一次异步投递，窗口可能已经重开。
    public static func expire(engine: FlowEngine, window: ExecutionWindow) async {
        window.setBackgroundTask(false)
        await engine.onLeaseExpired()
    }

    /// 短任务（BGAppRefreshTask）到期 / 20 秒到点：规则同 [expire]，只关短任务自己。
    public static func expireShort(engine: FlowEngine, window: ExecutionWindow) async {
        window.setShortTask(false)
        await engine.onLeaseExpired()
    }

    /// 宽限期（beginBackgroundTask）到期：规则同 [expire]，只关宽限期自己。
    public static func expireFinishingTime(engine: FlowEngine, window: ExecutionWindow) async {
        window.setFinishingTime(false)
        await engine.onLeaseExpired()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?

    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }

    func resume(_ value: Bool) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
