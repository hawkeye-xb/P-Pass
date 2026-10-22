// #340：引擎的 [WakeScheduler] 在 iOS 上的实现——把引擎登记的唤醒合进 [BackgroundWakePlan]、落盘，
// 再交给 [BackgroundTaskSubmitter]（薄层：BGTaskScheduler）挂成一条请求。
import Foundation

/// 薄层要实现的两件事（生产：`PPassBackgroundTasks.BGTaskSubmitter`；测试：记账的假实现）。
public protocol BackgroundTaskSubmitter: Sendable {
    /// 挂一条请求（同 identifier 的旧请求被替换）。系统拒绝时抛（模拟器 / 没开「后台 App 刷新」/ identifier 没登记）。
    func submit(_ spec: BackgroundTaskRequestSpec) throws
    /// 短任务（BGAppRefreshTask，#958）：同 identifier 再提交即替换。
    func submitShort(earliestBeginDate: Date) throws
    func cancelAll()
}

public final class PlannedWakeScheduler: WakeScheduler, @unchecked Sendable {
    public static let fileName = "background-wakes.json"
    private let url: URL
    private let submitter: BackgroundTaskSubmitter
    private let logger: CoreLogger
    private let now: @Sendable () -> Date
    private let isPaired: @Sendable () -> Bool
    private let lock = NSLock()

    /// [isPaired]（#1119）：未配对时不向系统挂任何请求（长任务 / 短任务都一样）——没有配对就没有要备份的东西，
    /// 重排只会让系统白白唤醒 App。唯一的挂请求入口是 `resubmit` / `ensureShortScheduled`，门禁就在这两处。
    public init(directory: URL, submitter: BackgroundTaskSubmitter, logger: CoreLogger, now: @escaping @Sendable () -> Date = { Date() },
                isPaired: @escaping @Sendable () -> Bool = { true }) {
        url = directory.appendingPathComponent(Self.fileName)
        self.submitter = submitter
        self.logger = logger
        self.now = now
        self.isPaired = isPaired
    }

    public var plan: BackgroundWakePlan {
        lock.lock(); defer { lock.unlock() }
        return JSONFile.read(BackgroundWakePlan.self, url, logger: logger) ?? BackgroundWakePlan()
    }

    /// 改计划 → 落盘 → 重新挂请求。提交失败不抛（尽力而为），但说实话：记日志。
    private func update(_ change: (inout BackgroundWakePlan) -> Void) {
        lock.lock()
        var p = JSONFile.read(BackgroundWakePlan.self, url, logger: logger) ?? BackgroundWakePlan()
        change(&p)
        do { try JSONFile.write(p, url) } catch { logger.log("background wakes: write failed (\(error))") }
        lock.unlock()
        resubmit(p)
    }

    private func resubmit(_ p: BackgroundWakePlan) {
        guard isPaired() else {
            logger.log("background wakes: not paired; not submitting")
            return
        }
        let spec = BackgroundWakePlanner.next(p, now: now())
        do {
            try submitter.submit(spec)
            logger.log("background wakes: submitted \(spec.reason.rawValue) earliest=\(spec.earliestBeginDate.map { "\($0.timeIntervalSince1970)" } ?? "now") power=\(spec.requiresExternalPower)")
        } catch {
            logger.log("background wakes: submit refused (\(error)); only foreground catch-up will run")
        }
    }

    /// 进程启动 / 回前台 / 每轮后台任务结束时调：按当前计划把请求挂上（保证至少挂着周期兜底）。
    public func ensureScheduled() {
        resubmit(plan)
    }

    /// 确保挂着一条短任务请求（earliestBeginDate = `shortTaskEarliest` 之后）。启动、回前台、进后台、被叫醒时都调；未配对时不挂。
    public func ensureShortScheduled() {
        guard isPaired() else {
            logger.log("short task: not paired; not submitting")
            return
        }
        do { try submitter.submitShort(earliestBeginDate: now().addingTimeInterval(BackgroundWakePlanner.shortTaskEarliest)) } catch {
            logger.log("short task: submit failed: \(error)")
        }
    }

    /// 系统按 [reason] 叫醒、这一轮跑完之后调：计划往前走一步并重新挂。
    public func didRun(_ reason: TriggerReason) {
        let at = now()
        update { $0 = BackgroundWakePlanner.afterRun($0, ran: reason, now: at) }
    }

    /// 断开（MOB-93 对位）：撤掉请求、清掉计划。
    public func stop() {
        lock.lock()
        try? FileManager.default.removeItem(at: url)
        lock.unlock()
        submitter.cancelAll()
    }

    // MARK: WakeScheduler

    public func scheduleUnreachableProbes() {
        let at = now().timeIntervalSince1970
        update { p in
            // 梯子没走完就不重排（对位 Android 探测梯的 KEEP）。
            if p.probeRung == nil {
                p.probeRung = 0
                p.probeAnchor = at
            }
        }
    }

    public func cancelUnreachableProbes() {
        update { $0.probeRung = nil; $0.probeAnchor = nil }
    }

    public func scheduleWhenConditionsMet(_ reason: WaitReason) {
        guard reason == .wifi || reason == .battery else { return }
        update { $0.constraint = reason.rawValue }
    }
}
