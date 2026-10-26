import UIKit
import UniformTypeIdentifiers

/// 诊断页「复制」写剪贴板的方式（#1152，MASWE-0030）：只写本机（`localOnly`，不经通用剪贴板同步到同一 Apple ID 的
/// 其他设备），并带过期时间——诊断文本里有版本、配对状态等，不该一直躺在剪贴板里被别的 App 读到。
enum DiagnosticsClipboard {
    /// 过期时间：够用户切到反馈渠道粘贴，又不会留太久。
    static let lifetime: TimeInterval = 120

    /// 剪贴板条目与选项（拆成纯函数是因为系统没有 API 能读回已写入的选项，测试只能断言这里构造的东西）。
    static func payload(for text: String, now: Date = Date()) -> (items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        ([[UTType.utf8PlainText.identifier: text]],
         [.localOnly: true, .expirationDate: now.addingTimeInterval(lifetime)])
    }

    static func copy(_ text: String, to pasteboard: UIPasteboard = .general) {
        let p = payload(for: text)
        pasteboard.setItems(p.items, options: p.options)
    }
}
