// #338：账本与偏好落在哪个目录。规划 I4：从第一天就放 App Group 容器（主 App 与将来的扩展共享）；
// 取不到容器（免费团队签不了 App Group、entitlement 缺失）时退回 App 私有目录——**必须说实话**：
// 既写日志，也把「降级了、为什么」放进返回值，诊断页能读到，不许看起来一切正常。
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
    public enum Kind: Equatable, Sendable {
        /// App Group 共享容器（规划要求的位置）。
        case appGroup
        /// 降级：App 私有目录。[reason] 是给人看的原因，诊断页原样展示。
        case appPrivateFallback(reason: String)
    }

    public let url: URL
    public let kind: Kind

    public var isDegraded: Bool {
        if case .appPrivateFallback = kind { return true }
        return false
    }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// 解析存储根。
    ///
    /// - Parameters:
    ///   - appGroupContainer: `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 的结果（调用方取，
    ///     核心不认识 group id）。nil = 取不到。
    ///   - groupIdentifier: 只用于日志与原因说明。
    ///   - appPrivateDirectory: 降级时用的目录（通常是 Application Support）。
    ///   - subdirectory: 根下 P-Pass 自己的子目录名；两种根用同一个名字，迁移时只换前缀。
    public static func resolve(
        appGroupContainer: URL?,
        groupIdentifier: String,
        appPrivateDirectory: URL,
        subdirectory: String = "PPass",
        fileManager: FileManager = .default,
        logger: CoreLogger
    ) throws -> StorageRoot {
        if let container = appGroupContainer {
            let url = container.appendingPathComponent(subdirectory, isDirectory: true)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                logger.log("storage: using App Group container \(groupIdentifier)")
                return StorageRoot(url: url, kind: .appGroup)
            } catch {
                let reason = "App Group 容器 \(groupIdentifier) 存在但不可写：\(error.localizedDescription)"
                return try fallback(appPrivateDirectory, subdirectory, reason, fileManager, logger)
            }
        }
        let reason = "取不到 App Group 容器 \(groupIdentifier)（签名没有这项 entitlement？），账本落在 App 私有目录，扩展读不到"
        return try fallback(appPrivateDirectory, subdirectory, reason, fileManager, logger)
    }

    private static func fallback(_ base: URL, _ sub: String, _ reason: String, _ fm: FileManager, _ logger: CoreLogger) throws -> StorageRoot {
        let url = base.appendingPathComponent(sub, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        logger.log("storage: DEGRADED — \(reason) (\(url.path))")
        return StorageRoot(url: url, kind: .appPrivateFallback(reason: reason))
    }
}
