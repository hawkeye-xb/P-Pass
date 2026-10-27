import Foundation
import PPassCore
import UIKit

/// 全 App 唯一的日志出口（#955）：同一行既进 NSLog（前台 `--console` 能看），也进容器内的滚动文件
/// `Library/Logs/ppass.log`（后台拉起时也能用 `tools/ios/pull-logs.sh` 取回）。
/// 隐私：落盘前过 `LogRedact.scrub`（媒体文件名、IP 地址、设备名、URL 主机名、长 ticket / token 串）；调用方仍应只写 hash 前缀与计数。
enum AppLog {
    static let fileName = "ppass.log"

    private static let sink: RollingFileLog? = {
        guard let lib = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let log = RollingFileLog(url: lib.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(fileName))
        // #1122：日志目录（App 容器 Library/Logs；日志不在 App Group 里）不进系统备份，结果记一行。
        let line = log.excludeDirectoryFromBackup()
        NSLog("[PPass] %@", line)
        log.write(line)
        return log
    }()

    /// 本机设备名：登记一次，之后任何日志行里出现都抹成 `<device>`（#1152）。
    private static let registeredOwnName: Void = LogRedact.registerDeviceNames([UIDevice.current.name])

    static func log(_ message: String) {
        _ = registeredOwnName
        let line = LogRedact.scrub(message)
        NSLog("[PPass] %@", line)
        sink?.write(line)
    }

    /// 进程启动记录。App 初始化时场景与后台任务都还没分发，`applicationState` 多半是 inactive，所以这里只把原始值当证据记下，
    /// 不据此下结论；真正的来源由 `LaunchOriginRecorder` 在第一个真实入口（场景 active / 后台任务回调）到达时记一行。
    @MainActor static func logLaunch() {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?")(\(info?["CFBundleVersion"] ?? "?"))"
        log("process start: pid=\(ProcessInfo.processInfo.processIdentifier) version=\(version) appState=\(state)")
    }
}
