// iOS 唯一真实存在的后台开关「后台 App 刷新」的状态。设置页告示（`AppModel.backgroundNotice`）与失败通知（`DefinitiveFacts`）据此判定。
// #343：首页不放「打开 P-Pass 时备份」之类的常驻说明（Android 也没有）；「后台不保证」的解释归 Q&A。
import Foundation

/// `UIApplication.backgroundRefreshStatus` 的对位（App 层读系统值传进来）。
public enum BackgroundRefreshAvailability: Equatable, Sendable {
    case available
    /// 用户在「设置 › 通用 › 后台 App 刷新」里关了（可以自己打开）。
    case denied
    /// 被屏幕使用时间 / 设备管理限制（用户自己打不开）。
    case restricted
}
