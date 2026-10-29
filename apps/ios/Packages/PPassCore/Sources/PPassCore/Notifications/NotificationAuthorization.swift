// #975：失败通知的授权语义。PPassCore 不 import UserNotifications，系统状态由 App 层映射成这三态。
//
// 对位 Android（MainActivity 的开关）。#1262 起 onboarding 不再申请通知，只在设置页拨开时申请：
// - 开关显示值 = 偏好 **且** 系统已授权，两者不会矛盾；
// - 拨开：已授权 → 直接写偏好；还没问过 → 申请，结果写回偏好；
// - 平台差异（登记在 06-ios-variants）：iOS 系统框只弹一次，denied 之后再申请不会有任何界面，
//   所以拨开时改为跳系统设置（Android 这里会再弹一次申请框，被拒两次后同样无界面）。
import Foundation

public enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public enum NotifyToggle {
    public enum TurnOnAction: Equatable, Sendable {
        case enable
        case requestAuthorization
        case openSystemSettings
    }

    public static func displayValue(preference: Bool, authorization: NotificationAuthorization) -> Bool {
        preference && authorization == .authorized
    }

    public static func turnOnAction(authorization: NotificationAuthorization) -> TurnOnAction {
        switch authorization {
        case .authorized: return .enable
        case .notDetermined: return .requestAuthorization
        case .denied: return .openSystemSettings
        }
    }

    /// 此刻系统会不会真的把通知展示出来。
    public static func canDeliver(_ authorization: NotificationAuthorization) -> Bool { authorization == .authorized }
}
