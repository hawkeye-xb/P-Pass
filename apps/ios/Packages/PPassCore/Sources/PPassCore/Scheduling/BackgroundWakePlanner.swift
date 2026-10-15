// #340（IOS-14）：`BGProcessingTask` 尽力而为的唤醒计划（纯逻辑，可测）。系统注册 / 提交在 PPassBackgroundTasks 这一薄层。
//
// Android 有 WorkManager：一条 5 小时周期兜底 + 探测梯（4 个一次性任务，10/20/40/80 分钟）+ 带约束的一次性唤醒，可以同时挂好几条。
// iOS 只有 BGTaskScheduler：同一个 identifier 同时只能挂一条请求（再提交就替换），系统自己挑时机，**不保证会跑**。
// 所以把 Android 的几条唤醒合成「下一条最该挂的请求」：
//   约束唤醒（Wi‑Fi / 电量）> 探测梯的当前一拍 > 5 小时周期兜底。跑完一次就按当前状态重新挂。
//
// 请求参数的取值与理由（卡面要求写清）：
// - `requiresNetworkConnectivity = true`（全部）：一轮要连桌面；没网时系统本就不该叫醒我们，叫醒了也只会进「等待中」。
//   注意 iOS 只能要求「有网」，不能要求「不计流量」——仅 Wi‑Fi 由引擎入口的 C-04 判据兜底，不靠系统。
// - 周期兜底 `requiresExternalPower = false`：长任务只在设备闲置时运行，备份逐张提交、中断后桌面端续传，
//   不插电的窗口同样有效；要求充电只会让系统少给运行机会（2026-10-13 定，见 #332、#959）。
// - 探测梯 / Wi‑Fi 约束 `requiresExternalPower = false`：它们要的是「条件一恢复就尽快试一次」，加充电要求会把一次短探测拖到深夜。
// - 电量约束 `requiresExternalPower = true`：Android 等的是「电量不低」，iOS 没有这个条件，插电是最接近的可表达条件。
import Foundation

/// 要提交给系统的一条 BGProcessingTask 请求（薄层照着它填 `BGProcessingTaskRequest`）。
public struct BackgroundTaskRequestSpec: Equatable, Sendable {
    public let identifier: String
    public let earliestBeginDate: Date?
    public let requiresNetworkConnectivity: Bool
    public let requiresExternalPower: Bool
    /// 系统叫醒时用哪个触发原因叫醒引擎。
    public let reason: TriggerReason
}

/// 唤醒计划的状态（落盘：后台启动是一个新进程，要知道上次挂的是哪一拍）。
public struct BackgroundWakePlan: Codable, Equatable, Sendable {
    /// 探测梯走到第几拍（nil = 没在走梯子）。
    public var probeRung: Int?
    /// 最近一次开始走梯子 / 走到当前一拍的时刻（秒）。
    public var probeAnchor: TimeInterval?
    /// 等着的约束（Wi‑Fi / 电量）的 rawValue。
    public var constraint: String?

    public init(probeRung: Int? = nil, probeAnchor: TimeInterval? = nil, constraint: String? = nil) {
        self.probeRung = probeRung
        self.probeAnchor = probeAnchor
        self.constraint = constraint
    }
}

public enum BackgroundWakePlanner {
    /// App 的 Info.plist `BGTaskSchedulerPermittedIdentifiers` 里必须有它。
    public static let identifier = "com.hawkeyexb.ppass.backup"
    /// #958：短任务（BGAppRefreshTask）的 identifier，同样要写进 Info.plist。
    public static let shortTaskIdentifier = "com.hawkeyexb.ppass.refresh"
    /// 短任务最早 5 分钟后再被叫醒（系统实际时机自己定）。
    public static let shortTaskEarliest: TimeInterval = 5 * 60
    /// 探测梯：与 Android `UNREACHABLE_PROBE_DELAYS_MINUTES` 同值（10 / 20 / 40 / 80 分钟）。
    public static let probeDelays: [TimeInterval] = [10, 20, 40, 80].map { $0 * 60 }
    /// 周期兜底：与 Android `PERIODIC_FALLBACK_HOURS` 同值（5 小时）。
    public static let periodicFallback: TimeInterval = 5 * 60 * 60

    /// 当前状态下最该挂的那一条请求。永远有一条（至少是周期兜底）。
    public static func next(_ plan: BackgroundWakePlan, now: Date) -> BackgroundTaskRequestSpec {
        if let raw = plan.constraint, let reason = WaitReason(rawValue: raw) {
            return BackgroundTaskRequestSpec(
                identifier: identifier, earliestBeginDate: nil, requiresNetworkConnectivity: true,
                requiresExternalPower: reason == .battery, reason: .constraintsMet
            )
        }
        if let rung = plan.probeRung, rung < probeDelays.count {
            let anchor = Date(timeIntervalSince1970: plan.probeAnchor ?? now.timeIntervalSince1970)
            return BackgroundTaskRequestSpec(
                identifier: identifier, earliestBeginDate: anchor.addingTimeInterval(probeDelays[rung]),
                requiresNetworkConnectivity: true, requiresExternalPower: false, reason: .unreachableProbe
            )
        }
        return BackgroundTaskRequestSpec(
            identifier: identifier, earliestBeginDate: now.addingTimeInterval(periodicFallback),
            requiresNetworkConnectivity: true, requiresExternalPower: false, reason: .periodic
        )
    }

    /// 系统按某条请求叫醒并跑完一轮之后，计划怎么往前走：约束唤醒用掉即清；探测走下一拍（4 拍走完就停，回到周期兜底）。
    /// 引擎在这一轮里若成功（`cancelUnreachableProbes`）或又登记了新的唤醒，会经 [PlannedWakeScheduler] 再改计划。
    public static func afterRun(_ plan: BackgroundWakePlan, ran reason: TriggerReason, now: Date) -> BackgroundWakePlan {
        var p = plan
        switch reason {
        case .constraintsMet:
            p.constraint = nil
        case .unreachableProbe:
            if let rung = p.probeRung {
                p.probeRung = rung + 1 < probeDelays.count ? rung + 1 : nil
                p.probeAnchor = p.probeRung == nil ? nil : now.timeIntervalSince1970
            }
        default:
            break
        }
        return p
    }
}
