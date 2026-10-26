// #338：账本与偏好落在哪个目录。#1172：存储根固定放 App 私有容器（Application Support/PPass）。
// 不放 App Group 共享容器：provider 的 redb 在进程存活期间一直持有 `blobs.db` 的文件锁，系统不允许挂起的进程持有
// 共享容器里的锁，挂起即以 0xdead10cc 终止（真机 runningboardd 原话：File locks MUST be held in <App 容器>）。
// App 私有容器内的锁系统不检查。iOS 没有扩展需要共享这些状态（背景上传扩展已不做，#341），BGTask 跑在主 App 进程里。
import Foundation

/// 日志出口。核心不直接碰 OSLog（host 单测要能截获每一行）。
public protocol CoreLogger: Sendable {
    func log(_ message: String)
}

/// 什么都不记（测试里不关心日志的地方用）。
public struct NoopLogger: CoreLogger {
    public init() {}
    public func log(_ message: String) {}
}

public struct StorageRoot: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 解析存储根：[appPrivateDirectory]（通常是 Application Support）下的 [subdirectory]，不存在就建。
    public static func resolve(
        appPrivateDirectory: URL,
        subdirectory: String = "PPass",
        fileManager: FileManager = .default,
        logger: CoreLogger
    ) throws -> StorageRoot {
        let url = appPrivateDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        logger.log("storage: using app container \(url.path)")
        excludeFromBackup(url, logger)
        return StorageRoot(url: url)
    }

    /// 整个存储根不进 iCloud / Finder 备份、不随换机迁移（对位 Android `allowBackup=false`）：配对与本次安装的标记
    /// 属于这台设备，恢复到别的手机上就是一台新设备。设在目录上——里面的文件都是原子写（新文件 + rename），
    /// 设在文件上每写一次就丢。每次启动都设一次（幂等）。系统只把它当建议，真正的兜底是 [DeviceIdentity] 的新设备判定。
    static func excludeFromBackup(_ url: URL, _ logger: CoreLogger) {
        var dir = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try dir.setResourceValues(values)
            let readBack = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            logger.log("storage: \(url.lastPathComponent) excluded from backup = \(readBack.map(String.init(describing:)) ?? "unknown")")
        } catch {
            logger.log("storage: could not exclude \(url.lastPathComponent) from backup: \(error)")
        }
    }
}
