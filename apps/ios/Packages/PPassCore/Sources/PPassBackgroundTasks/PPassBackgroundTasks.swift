// #340：BGTaskScheduler 的薄层——App 直接调用，业务判断全在 PPassCore（BackgroundWakePlanner / BackgroundRun）。
//
// App 侧接线点（App 线集成时照做）：
// 1. Info.plist：`BGTaskSchedulerPermittedIdentifiers` 加 `BackgroundWakePlanner.identifier`（com.hawkeyexb.ppass.backup）；
//    `UIBackgroundModes` 加 `processing`。
// 2. 启动时（`application(_:didFinishLaunchingWithOptions:)` 返回之前，或 SwiftUI App 的 init 里）调 `PPassBackgroundTasks.register(...)`：
//    系统要求所有 identifier 在启动完成前注册完，晚了 `submit` 会被拒。
// 3. 构造引擎时把 `PlannedWakeScheduler(directory:submitter: BGTaskSubmitter(), …)` 作为 WakeScheduler 注入，
//    `ExecutionWindow()` 作为 ExecutionLease 注入；进程启动、回前台时调一次 `scheduler.ensureScheduled()`。
// 4. scenePhase：.active → `window.setAppActive(true)` + `ForegroundCatchup.appDidBecomeActive()`；
//    .background → `window.setAppActive(false)`，并用 `UIApplication.beginBackgroundTask` 申请收尾时间
//    （开始 `window.setFinishingTime(true)`；expiration / 结束 `window.setFinishingTime(false)` + `engine.onLeaseExpired()`）。
// 5. 断开（DisconnectRuntime.cancelScheduledWakes）调 `scheduler.stop()`。
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
    }
}

public enum PPassBackgroundTasks {
    /// 注册后台任务的 launch handler。返回 false = 系统不接受（identifier 没写进 Info.plist）。
    /// [reasonForLaunch] 返回这次被叫醒该用的触发原因（生产：`BackgroundWakePlanner.next(scheduler.plan, now:).reason`）。
    @discardableResult
    public static func register(
        engine: FlowEngine,
        window: ExecutionWindow,
        scheduler: PlannedWakeScheduler,
        logger: CoreLogger
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundWakePlanner.identifier, using: nil) { task in
            let reason = BackgroundWakePlanner.next(scheduler.plan, now: Date()).reason
            logger.log("background task launched (\(reason.rawValue))")
            let work = Task {
                let ok = await BackgroundRun.run(engine: engine, window: window, scheduler: scheduler, reason: reason)
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
#endif
