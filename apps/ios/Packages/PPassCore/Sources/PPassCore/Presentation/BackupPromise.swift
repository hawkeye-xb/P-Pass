// #343（IOS-17）：把 iOS 不承诺什么如实告诉用户——状态模型（文案 key + 何时出现），文案本身在 assets/i18n（四处同步）。
//
// 红线（卡面验收）：
// - 不用「自动备份」这种会被误读的措辞：首页常驻的是「打开 P-Pass 时备份」，后台只说「iOS 可能补跑，不保证」。
// - 不出现任何未实测的频率 / 滞后数字（IOS-03 第 6 问没有结论之前）——测试逐条扫文案里的数字。
// - 不复刻 Android 的电池白名单 / 开机重挂 / 启动管理引导：iOS 没有对应物；iOS 真实存在的开关只有「后台 App 刷新」。
import Foundation

/// `UIApplication.backgroundRefreshStatus` 的对位（App 层读系统值传进来）。
public enum BackgroundRefreshAvailability: Equatable, Sendable {
    case available
    /// 用户在「设置 › 通用 › 后台 App 刷新」里关了（可以自己打开）。
    case denied
    /// 被屏幕使用时间 / 设备管理限制（用户自己打不开）。
    case restricted
}

/// 首页要显示的一条告示：一个 i18n key + 占位符。
public struct PromiseNotice: Equatable, Sendable {
    public let key: String
    public let vars: [String: String]

    public init(_ key: String, vars: [String: String] = [:]) {
        self.key = key
        self.vars = vars
    }
}

public enum BackupPromise {
    public static let whileOpenTitle = "ui.ios_backup_while_open_title"
    public static let whileOpenBody = "ui.ios_backup_while_open_body"
    public static let refreshOff = "ui.ios_background_refresh_off"
    public static let refreshRestricted = "ui.ios_background_refresh_restricted"
    public static let waitOpenApp = "ui.ios_wait_open_app"
    public static let waitICloudOriginal = "ui.ios_wait_icloud_original"
    public static let waitPhoneStorageFull = "ui.ios_wait_phone_storage_full"
    /// 复用既有 key（「最近备份 {time}」）：#340 评论——首页要能看出上次成功是什么时候，后台没跑时用户自己能发现。
    public static let lastBackup = "ui.device_last_backup"

    /// 本模型可能产出的全部 key（测试据此核对 assets/i18n 里都有、且不含数字）。
    public static let allKeys = [whileOpenTitle, whileOpenBody, refreshOff, refreshRestricted, waitOpenApp, waitICloudOriginal, waitPhoneStorageFull, lastBackup]

    /// 首页告示，按显示顺序：常驻的「打开时备份」→ 后台刷新不可用时的说明 → iOS 特有的等待原因 → 最近一次成功。
    /// Android 与 iOS 共有的等待原因（未配对、仅 Wi‑Fi、桌面不可达……）由共享的首页投影负责，这里不重复。
    public static func notices(view: EngineView, backgroundRefresh: BackgroundRefreshAvailability, lastConfirmedAt: Date?, formatTime: (Date) -> String) -> [PromiseNotice] {
        var out = [PromiseNotice(whileOpenTitle), PromiseNotice(whileOpenBody)]
        switch backgroundRefresh {
        case .available: break
        case .denied: out.append(PromiseNotice(refreshOff))
        case .restricted: out.append(PromiseNotice(refreshRestricted))
        }
        if view.state == .waiting, let reason = view.waitReason {
            switch reason {
            case .executionBlocked: out.append(PromiseNotice(waitOpenApp))
            case .originalUnavailable: out.append(PromiseNotice(waitICloudOriginal))
            case .localStorageFull: out.append(PromiseNotice(waitPhoneStorageFull))
            case .notPaired, .disabled, .wifi, .battery, .desktopUnreachable, .desktopStorageFull, .desktopLibraryUnavailable, .desktopStorageError, .unexpectedError:
                break
            }
        }
        if let at = lastConfirmedAt { out.append(PromiseNotice(lastBackup, vars: ["time": formatTime(at)])) }
        return out
    }
}
