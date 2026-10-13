// #340：iOS 的执行租约（Android FGS + wakelock 的对位）与一次后台任务的跑法。
//
// iOS 上能让循环跑的「执行时间」只有三种来源：App 在前台；`beginBackgroundTask` 给的收尾时间（刚退到后台的几十秒）；
// 系统按 BGProcessingTask 给的窗口。[ExecutionWindow] 把它们合成一个租约：任一个开着就算持有。
// 窗口全部关掉（App 退后台且收尾时间用完、后台任务到期）时，App 层调 `engine.onLeaseExpired()`——引擎停循环、
// 传输端口有界地发 `flow.suspend`、在飞的那张保持传输中、等待中（EXECUTION_BLOCKED）。
import Foundation

public final class ExecutionWindow: ExecutionLease, @unchecked Sendable {
    private let lock = NSLock()
    private var appActive = false
    private var finishingTime = false
    private var backgroundTask = false
    private var acquired = false
    private var lastStatus = LoopStatus()

    public init() {}

    private func open() -> Bool { appActive || finishingTime || backgroundTask }

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

    /// 系统收回后台时间（expirationHandler）：先关窗口，再让引擎按「执行时间被收回」停下（在飞的那张保持传输中）。
    public static func expire(engine: FlowEngine, window: ExecutionWindow) async {
        window.setBackgroundTask(false)
        await engine.onLeaseExpired()
    }
}
