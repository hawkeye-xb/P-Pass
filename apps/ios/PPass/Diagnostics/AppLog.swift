import Foundation
import PPassCore
import UIKit

/// 全 App 唯一的日志出口（#955）：同一行既进 NSLog（前台 `--console` 能看），也进容器内的滚动文件
/// `Library/Logs/ppass.log`（后台拉起时也能用 `tools/ios/pull-logs.sh` 取回）。
/// 隐私：落盘前过 `LogRedact.scrub`（媒体文件名、≥32 字符的 ticket / token 串）；调用方仍应只写 hash 前缀与计数。
enum AppLog {
    static let fileName = "ppass.log"

    private static let sink: RollingFileLog? = {
        guard let lib = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return RollingFileLog(url: lib.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(fileName))
    }()

    static func log(_ message: String) {
        let line = LogRedact.scrub(message)
        NSLog("[PPass] %@", line)
        sink?.write(line)
    }

    /// 进程启动来源。BGTask / 静默唤醒拉起的进程在 App 初始化时 applicationState 是 background；用户点开是 inactive。
    /// 取不到（极早期）就如实写 unknown，不猜。
    @MainActor static func logLaunch() {
        let origin: String
        switch UIApplication.shared.applicationState {
        case .background: origin = "background (BGTask / silent wake)"
        case .inactive, .active: origin = "foreground"
        @unknown default: origin = "unknown"
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?")(\(info?["CFBundleVersion"] ?? "?"))"
        log("process start: origin=\(origin) pid=\(ProcessInfo.processInfo.processIdentifier) version=\(version)")
    }
}
