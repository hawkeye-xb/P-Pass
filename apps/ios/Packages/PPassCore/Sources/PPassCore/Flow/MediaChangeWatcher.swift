// #978：App 在前台时的相册变化监听。对位 Android `BackupUiStateHolder` 的 MediaStore ContentObserver：
// 变化 → `gateway.onMediaChanged()`（FOREGROUND_MEDIA_CHANGE，人在场不查后台开关）+ 重算首页计数。
//
// 本文件只放平台无关的两件事，PhotoKit 的注册在 App 层（`PhotoLibraryChangeSource`）：
// - `MediaChangeWatcher`：监听的生命周期（注册 / 注销 / 条件不满足时不注册并留日志）。
// - `ForegroundMediaChange`：一次变化通知该做什么（重算计数；在前台才叫醒引擎）。
//
// iOS 后台不会因相册变化唤醒 App（BackgroundWakePlanner 头注释；对位 Android 后台 MediaWatchJob 的差异登记在
// 06-ios-variants「前台相册变化监听」）：所以这里没有后台路径，后台新增的照片靠回前台追赶 / BGTask 周期兜底。
import Foundation

/// 相册变化的来源。生产是 `PHPhotoLibraryChangeObserver`，测试里换成假的。`onChange` 可能在任意线程上被调用。
public protocol MediaChangeSource: AnyObject {
    func start(_ onChange: @escaping @Sendable () -> Void)
    func stop()
}

public final class MediaChangeWatcher: @unchecked Sendable {
    private let source: MediaChangeSource
    private let unavailableReason: @Sendable () -> String?
    private let onChange: @Sendable () -> Void
    private let logger: CoreLogger
    private let lock = NSLock()
    private var registration: Int?
    private var generation = 0
    private var lastLoggedReason: String?

    /// - Parameters:
    ///   - unavailableReason: 现在为什么不该监听（未配对 / 相册没授权……）；nil = 可以监听。
    ///   - onChange: 一次变化通知（已排除旧注册的在途回调）。
    public init(source: MediaChangeSource, unavailableReason: @escaping @Sendable () -> String?,
                onChange: @escaping @Sendable () -> Void, logger: CoreLogger) {
        self.source = source
        self.unavailableReason = unavailableReason
        self.onChange = onChange
        self.logger = logger
    }

    public var isRegistered: Bool { lock.lock(); defer { lock.unlock() }; return registration != nil }

    /// 注册（幂等：已注册直接返回 true）。条件不满足不注册、返回 false，并把原因记进日志（同一原因只记一次）。
    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if registration != nil { return true }
        if let reason = unavailableReason() {
            if lastLoggedReason != reason { logger.log("media-change: observer not registered: \(reason)") }
            lastLoggedReason = reason
            return false
        }
        lastLoggedReason = nil
        generation += 1
        let mine = generation
        registration = mine
        source.start { [weak self] in self?.fire(registration: mine) }
        logger.log("media-change: observer registered")
        return true
    }

    /// 注销（断开清单的 `stopMediaChangeObserver`）。没注册时不动 source。
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard registration != nil else { return }
        registration = nil
        source.stop()
        logger.log("media-change: observer unregistered")
    }

    private func fire(registration mine: Int) {
        lock.lock()
        let live = registration == mine
        lock.unlock()
        if live { onChange() }
    }
}

/// 一次相册变化通知的处理：先重算首页计数（Android `scheduleRefresh(recount = true)`，不依赖前台与否），
/// 在前台再以 FOREGROUND_MEDIA_CHANGE 叫醒引擎（Android `if (isAppVisible()) engine.trigger(...)`）。
/// 先重算、后触发：计数不依赖引擎这一轮，先给；引擎起轮后的视图变化会再推一次首页事实。
public struct ForegroundMediaChange: Sendable {
    private let isForeground: @Sendable () -> Bool
    private let recount: @Sendable () async -> Void
    private let trigger: @Sendable (TriggerReason) async -> Void
    private let logger: CoreLogger

    public init(isForeground: @escaping @Sendable () -> Bool, recount: @escaping @Sendable () async -> Void,
                trigger: @escaping @Sendable (TriggerReason) async -> Void, logger: CoreLogger = NoopLogger()) {
        self.isForeground = isForeground
        self.recount = recount
        self.trigger = trigger
        self.logger = logger
    }

    public func handle() async {
        await recount()
        guard isForeground() else {
            logger.log("media-change: not foreground, recount only")
            return
        }
        logger.log("media-change: trigger \(TriggerReason.foregroundMediaChange.rawValue)")
        await trigger(.foregroundMediaChange)
    }
}
