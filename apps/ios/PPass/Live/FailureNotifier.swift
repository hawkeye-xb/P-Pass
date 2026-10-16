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

/// 失败本地通知（Android `DefinitiveEventNotices`，#130 / #981）：只发三类确定事件——配对失效、相册权限变差、
/// 「后台 App 刷新」被关；「备份出问题」不发（#418）。触发与去重是 PPassCore 的纯判定 + 落盘状态，这里只负责发 / 撤。
/// iOS 上通知只能在 App 有执行时间时发出（前台，或后台任务拉起的那一轮），这是平台限制，不是遗漏。
/// #975：发之前读系统真实授权；未授权不静默吞掉——不发、状态不推进，每类事件只记一行日志。
enum FailureNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loggedUndeliverable: Set<NoticeEvent> = []

    /// 评估 → 先落盘 → 发 / 撤。幂等；落盘失败只记日志（App 内红卡 / 告示才是状态真相，通知是补充渠道）。
    static func evaluate(facts: DefinitiveFacts, notifyEnabled: Bool, store: DefinitiveNoticeStore, logger: CoreLogger) async {
        let auth = await SystemNotifications.authorization()
        let deliverable = notifyEnabled && NotifyToggle.canDeliver(auth)
        let decision: DefinitiveDecision
        do { decision = try DefinitiveEventMonitor.evaluate(store: store, facts: facts, deliverable: deliverable) }
        catch { logger.log("notify: cannot persist definitive_notices.json (\(error)); not posting"); return }

        lock.lock()
        for event in decision.undeliverable where loggedUndeliverable.insert(event).inserted {
            logger.log("notify: \(event.rawValue) not delivered, enabled=\(notifyEnabled) system authorization=\(auth)")
        }
        // 发出去了或已恢复的事件，下次再不可送达时重新记一行。
        loggedUndeliverable.subtract(decision.post.map(\.event))
        loggedUndeliverable.subtract(decision.cancel)
        lock.unlock()

        let center = UNUserNotificationCenter.current()
        let cancelIds = decision.cancel.map(\.notificationIdentifier)
        if !cancelIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: cancelIds)
            center.removePendingNotificationRequests(withIdentifiers: cancelIds)
        }
        for notice in decision.post {
            let (title, body) = text(for: notice)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let id = notice.event.notificationIdentifier
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                guard let error else { return }
                // 状态已落盘，这一条不会自动补发；留日志，真机才能判定。
                logger.log("notify: \(id) add failed: \(error)")
            }
        }
    }

    /// 文案：配对失效 / 相册标题复用 Android 的 key，正文用 Android 通知专用的 key；iOS 说法不同的在 IOS.strings 里覆盖。
    private static func text(for notice: NoticeKind) -> (title: String, body: String) {
        switch notice {
        case .pairingLost:
            return (L.s("pairing_lost_title"), L.s("notif_pairing_lost_body"))
        case .mediaAccessRevoked(let now):
            return now == .none
                ? (L.s("no_media_access_title"), L.s("notif_media_none_body"))
                : (L.s("partial_access_title"), L.s("notif_media_partial_body"))
        case .backgroundRefreshOff(let restricted):
            return (L.s("notif_background_refresh_off_title"),
                    L.s(restricted ? "notif_background_refresh_restricted_body" : "notif_background_refresh_off_body"))
        }
    }
}
