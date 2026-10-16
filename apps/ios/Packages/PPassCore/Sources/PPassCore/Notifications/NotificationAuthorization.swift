// #975：失败通知的授权语义。PPassCore 不 import UserNotifications，系统状态由 App 层映射成这三态。
//
// 对位 Android（`OnboardingNotificationAsk` + MainActivity 的开关）：
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

/// Android 13+ 在 onboarding 完成页**只问一次**通知权限（`OnboardingNotificationAsk.kt`，#130）。
/// 文件名与字段同 Android；先落盘「已问过」再弹；老用户升级不问；损坏按「已问过」，缺失按「不问」。
/// iOS 没有 SDK 版本分支；`shouldAsk` 额外要求系统仍是 notDetermined——否则系统不会弹框。
public final class OnboardingNotificationAsk: @unchecked Sendable {
    public static let fileName = "onboarding_notification_ask.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    struct State: Codable, Equatable {
        var asked: Bool = false
        var skippedAsExistingUser: Bool = false
    }

    /// 第一次运行时定下这台机器是不是老用户；文件已存在什么都不做（幂等）。
    public func initIfAbsent(existingUser: Bool) {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do { try JSONFile.write(State(asked: existingUser, skippedAsExistingUser: existingUser), url) }
        catch { logger.log("notification-ask: init failed: \(error)") }
    }

    public func shouldAsk(authorization: NotificationAuthorization) -> Bool {
        guard authorization == .notDetermined, let state = load() else { return false }
        return !state.asked
    }

    /// 发起系统申请**之前**调用：先落盘，申请中途进程被杀也不会再问。
    public func markAsked() throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        var state = loadLocked() ?? State()
        state.asked = true
        try JSONFile.write(state, url)
    }

    /// 系统弹窗结果：开关跟着授权结果走。
    public func onResult(granted: Bool, prefs: NotifyOnFailurePrefs) throws {
        try prefs.setEnabled(granted)
    }

    func load() -> State? {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return JSONFile.read(State.self, url, logger: logger) ?? State(asked: true)
    }
}
