import Foundation
import UserNotifications

/// 失败本地通知（Android `rule_notify`）：配对失效 / 备份出问题时提醒一次；状况解除后再出现才会再提醒。
/// iOS 上通知只能在 App 有执行时间时发出（前台或后台唤醒那一轮），这是平台限制，不是遗漏。
enum FailureNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var notified: Set<String> = []

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func update(pairingLost: Bool, trouble: Bool) {
        post(key: "pairing_lost", active: pairingLost, title: L.s("pairing_lost_title"), body: L.s("pairing_lost_body"))
        post(key: "trouble", active: trouble, title: L.s("state_trouble"), body: L.s("run_failed"))
    }

    private static func post(key: String, active: Bool, title: String, body: String) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { notified.remove(key); return }
        guard notified.insert(key).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ppass.\(key)", content: content, trigger: nil))
    }
}
