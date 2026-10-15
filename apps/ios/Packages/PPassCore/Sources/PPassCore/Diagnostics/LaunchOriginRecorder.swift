import Foundation

/// 进程启动来源（#958）。App 初始化时场景与后台任务都还没分发，`applicationState` 不可信，所以不在那时猜；
/// 等第一个真实入口到达（场景第一次 active / 后台任务回调）再记，整个进程只记一次，先到者赢。
public final class LaunchOriginRecorder: @unchecked Sendable {
    public static let shared = LaunchOriginRecorder()

    private let lock = NSLock()
    private var recorded = false

    public init() {}

    /// 场景第一次变成 active。
    public func foregroundReached(logger: CoreLogger) {
        record("foreground", logger: logger)
    }

    /// 后台任务回调先到（短任务 / 长任务），[identifier] 为任务标识。
    public func backgroundTaskReached(identifier: String, logger: CoreLogger) {
        record("background (\(identifier))", logger: logger)
    }

    private func record(_ origin: String, logger: CoreLogger) {
        lock.lock()
        let first = !recorded
        recorded = true
        lock.unlock()
        if first { logger.log("launch origin: \(origin)") }
    }
}
