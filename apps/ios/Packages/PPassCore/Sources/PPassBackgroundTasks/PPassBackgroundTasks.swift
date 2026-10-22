// #340：BGTaskScheduler 的薄层——App 直接调用，业务判断全在 PPassCore（BackgroundWakePlanner / BackgroundRun）。
//
// App 侧接线点（App 线集成时照做）：
// 1. Info.plist：`BGTaskSchedulerPermittedIdentifiers` 加 `BackgroundWakePlanner.identifier`（com.hawkeyexb.ppass.backup）；
//    `UIBackgroundModes` 加 `processing`。
// 2. 启动时（`application(_:didFinishLaunchingWithOptions:)` 返回之前，或 SwiftUI App 的 init 里）调 `PPassBackgroundTasks.register(logger:target:)`，
//    不等 App 的其余部分起来（target 被叫醒时才取）：
//    系统要求所有 identifier 在启动完成前注册完，晚了 `submit` 会被拒。
// 3. 构造引擎时把 `PlannedWakeScheduler(directory:submitter: BGTaskSubmitter(), …)` 作为 WakeScheduler 注入，
//    `ExecutionWindow()` 作为 ExecutionLease 注入；进程启动、回前台时调一次 `scheduler.ensureScheduled()`。
// 4. scenePhase：.active → `window.setAppActive(true)` + `ForegroundCatchup.appDidBecomeActive()`；
//    .background → `window.setAppActive(false)`，并用 `UIApplication.beginBackgroundTask` 申请收尾时间
//    （开始 `window.setFinishingTime(true)`；结束 `window.setFinishingTime(false)`；expiration 在 handler 里同步关窗口、
//    同步 `endBackgroundTask`，再异步 `engine.onLeaseExpired()`——停不停由引擎按此刻的租约定，#1007）。
// 5. 断开（DisconnectRuntime.cancelScheduledWakes）调 `scheduler.stop()`。
// 短任务（#958）：identifier `BackgroundWakePlanner.shortTaskIdentifier`（com.hawkeyexb.ppass.refresh）也要进 Info.plist，
//   `UIBackgroundModes` 再加 `fetch`；启动 / 回前台 / 进后台调 `ensureShortScheduled()`。
// 模拟器验证：在 launch 之后用 LLDB
//   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.hawkeyexb.ppass.backup"]
// 触发一次（只在调试器里可用）。
#if canImport(BackgroundTasks) && canImport(UIKit)
import BackgroundTasks
import Foundation
import PPassCore

/// [BackgroundTaskSubmitter] 的 BGTaskScheduler 实现。
public struct BGTaskSubmitter: BackgroundTaskSubmitter {
    public init() {}

    public func submit(_ spec: BackgroundTaskRequestSpec) throws {
        let request = BGProcessingTaskRequest(identifier: spec.identifier)
        request.earliestBeginDate = spec.earliestBeginDate
        request.requiresNetworkConnectivity = spec.requiresNetworkConnectivity
        request.requiresExternalPower = spec.requiresExternalPower
        try BGTaskScheduler.shared.submit(request)
    }

    public func cancelAll() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundWakePlanner.identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundWakePlanner.shortTaskIdentifier)
    }
}

/// 后台任务被叫醒时要用到的那一套（引擎、执行窗口、唤醒计划）。App 起不来时没有。
public struct BackgroundTarget: Sendable {
    public let engine: FlowEngine
    public let window: ExecutionWindow
    public let scheduler: PlannedWakeScheduler
    public let afterRun: @Sendable () async -> Void

    public init(engine: FlowEngine, window: ExecutionWindow, scheduler: PlannedWakeScheduler, afterRun: @escaping @Sendable () async -> Void = {}) {
        self.engine = engine
        self.window = window
        self.scheduler = scheduler
        self.afterRun = afterRun
    }
}

public enum PPassBackgroundTasks {
    /// 注册后台任务的 launch handler。返回 false = 系统不接受（identifier 没写进 Info.plist）。
    /// 注册不依赖 App 起没起来：系统按 identifier 拉起进程而 handler 没注册会直接崩。[target] 在被叫醒时才取——
    /// 开机后还没解锁过（读不到钥匙串里的身份）或起不来时为 nil，这一次直接交还系统（失败），短任务照常挂下一次。
    /// 被叫醒时的触发原因按 `BackgroundWakePlanner.next(target.scheduler.plan, now:).reason` 取。
    @discardableResult
    public static func register(logger: CoreLogger, target: @escaping @Sendable () -> BackgroundTarget?) -> Bool {
        let shortOK = registerShortTask(logger: logger, target: target)
        return registerLongTask(logger: logger, target: target) && shortOK
    }

    /// #958：短任务（BGAppRefreshTask）。每次被叫醒先挂下一次；已有其他窗口开着就直接完成；20 秒自收尾；`setTaskCompleted` 必调一次。
    private static func registerShortTask(logger: CoreLogger, target: @escaping @Sendable () -> BackgroundTarget?) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundWakePlanner.shortTaskIdentifier, using: nil) { task in
            LaunchOriginRecorder.shared.backgroundTaskReached(identifier: BackgroundWakePlanner.shortTaskIdentifier, logger: logger)
            ensureShortScheduled(logger: logger)
            guard let t = target() else {
                logger.log("short task: app not ready (identity locked or unavailable); finishing without a run")
                task.setTaskCompleted(success: false)
                return
            }
            let engine = t.engine, window = t.window, afterRun = t.afterRun
            let completed = CompletionOnce(task)
            let work = Task {
                let ok = await BackgroundRun.runShort(engine: engine, window: window, logger: logger)
                await afterRun() // 先评估再交还系统：完成之后进程随时会被挂起
                completed.complete(success: ok)
            }
            task.expirationHandler = {
                logger.log("short task: expired by the system (finish=system_expired)")
                work.cancel()
                Task {
                    await BackgroundRun.expireShort(engine: engine, window: window)
                    completed.complete(success: true)
                }
            }
        }
    }

    /// 确保挂着一条短任务请求（earliestBeginDate = 5 分钟）。同 identifier 再提交即替换。启动、回前台、进后台、被叫醒时都调。
    public static func ensureShortScheduled(logger: CoreLogger? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundWakePlanner.shortTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(BackgroundWakePlanner.shortTaskEarliest)
        do { try BGTaskScheduler.shared.submit(request) } catch { logger?.log("short task: submit failed: \(error)") }
    }

    private static func registerLongTask(logger: CoreLogger, target: @escaping @Sendable () -> BackgroundTarget?) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundWakePlanner.identifier, using: nil) { task in
            LaunchOriginRecorder.shared.backgroundTaskReached(identifier: BackgroundWakePlanner.identifier, logger: logger)
            guard let t = target() else {
                // 唤醒计划在存储根里，此刻读不到；短任务已挂着，App 起来后 scheduler.ensureScheduled() 会补挂长任务。
                logger.log("background task: app not ready (identity locked or unavailable); finishing without a run")
                task.setTaskCompleted(success: false)
                return
            }
            let engine = t.engine, window = t.window, scheduler = t.scheduler, afterRun = t.afterRun
            let reason = BackgroundWakePlanner.next(scheduler.plan, now: Date()).reason
            logger.log("background task launched (\(reason.rawValue))")
            let work = Task {
                let ok = await BackgroundRun.run(engine: engine, window: window, scheduler: scheduler, reason: reason)
                await afterRun() // 先评估再交还系统：完成之后进程随时会被挂起
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = {
                logger.log("background task expired")
                work.cancel()
                Task { await BackgroundRun.expire(engine: engine, window: window) }
            }
        }
    }
}

/// `setTaskCompleted` 只能调一次（到期收尾与正常完成会竞争）。
private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let task: BGTask

    init(_ task: BGTask) { self.task = task }

    func complete(success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { task.setTaskCompleted(success: success) }
    }
}
#endif
