import Foundation
import PPassCore
import UIKit
import UserNotifications

extension NotificationAuthorization {
    /// provisional / ephemeral 能把通知交付出来（静默 / 限时），按已授权；其余未知值保守按 denied。
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized, .provisional, .ephemeral: self = .authorized
        default: self = .denied
        }
    }
}

/// 系统通知中心的薄封装：授权状态只在这里读，别处不缓存成「真值」。
enum SystemNotifications {
    static func authorization() async -> NotificationAuthorization {
        NotificationAuthorization(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// 弹系统授权框（只在 notDetermined 时有界面）；返回用户是否点了允许。
    static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    @MainActor static func openSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// 发一条失败通知之前的裁决（纯函数，可测）。
enum NotifyGate {
    enum Decision: Equatable {
        /// 状况解除：清掉「已提醒」记号，下次再出现才会再提醒。
        case clear
        /// 同一次状况已经提醒过。
        case alreadyNotified
        /// 系统没授权，发了也会被丢弃：不发、不记「已提醒」（授权之后这次状况仍要提醒），并留日志。
        case undeliverable
        case post
    }

    static func decide(active: Bool, alreadyNotified: Bool, authorization: NotificationAuthorization) -> Decision {
        guard active else { return .clear }
        guard !alreadyNotified else { return .alreadyNotified }
        return NotifyToggle.canDeliver(authorization) ? .post : .undeliverable
    }
}

/// 失败本地通知（Android `rule_notify`）：配对失效 / 备份出问题时提醒一次；状况解除后再出现才会再提醒。
/// iOS 上通知只能在 App 有执行时间时发出（前台或后台唤醒那一轮），这是平台限制，不是遗漏。
/// #975：发之前读系统真实授权；未授权不静默吞掉——每次状况只记一行日志（授权状态在设置页开关上可见）。
enum FailureNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var notified: Set<String> = []
    nonisolated(unsafe) private static var loggedUndeliverable: Set<String> = []

    static func update(pairingLost: Bool, trouble: Bool, logger: CoreLogger) async {
        let auth = await SystemNotifications.authorization()
        post(key: "pairing_lost", active: pairingLost, auth: auth, logger: logger,
             title: L.s("pairing_lost_title"), body: L.s("pairing_lost_body"))
        post(key: "trouble", active: trouble, auth: auth, logger: logger,
             title: L.s("state_trouble"), body: L.s("run_failed"))
    }

    private static func post(key: String, active: Bool, auth: NotificationAuthorization, logger: CoreLogger, title: String, body: String) {
        lock.lock()
        let decision = NotifyGate.decide(active: active, alreadyNotified: notified.contains(key), authorization: auth)
        switch decision {
        case .clear: notified.remove(key); loggedUndeliverable.remove(key)
        case .alreadyNotified: break
        case .undeliverable: if loggedUndeliverable.insert(key).inserted { logger.log("notify: \(key) not delivered, system authorization=\(auth)") }
        case .post: notified.insert(key)
        }
        lock.unlock()
        guard decision == .post else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ppass.\(key)", content: content, trigger: nil)) { error in
            guard let error else { return }
            logger.log("notify: \(key) add failed: \(error)")
            lock.lock(); notified.remove(key); lock.unlock() // 没发出去就不算提醒过，下一轮再试
        }
    }
}
