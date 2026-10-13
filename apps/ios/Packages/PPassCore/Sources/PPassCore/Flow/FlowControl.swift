// 意图层的暂停标志 + 持久化的等待原因 + 最近一次执行租约受阻原因（对位 Android `FlowControlStore.kt` / `FlowControl`）。
//
// 与 Android 的差异（登记在 iOS 变体文档）：
//   - 没有 #522 的 FGS 额度事实（开机序号 / elapsedRealtime）：iOS 没有 dataSync FGS 额度这回事。
//   - `FGS_BLOCKED` → `EXECUTION_BLOCKED`：iOS 的「执行租约」是前台 / 后台任务时间，不是前台服务。
//   - 新增 `ORIGINAL_UNAVAILABLE`：iCloud 原图因网络拉不下来（#311 D4），不计次、等网络。
import Foundation

/// 全局「等待中」的原因。由我们自动恢复，持久化（进程重启后还在）。持久化存 rawValue，**不许改名**。
public enum WaitReason: String, CaseIterable, Codable, Sendable {
    case notPaired = "NOT_PAIRED"
    case disabled = "DISABLED"
    case wifi = "WIFI"
    case battery = "BATTERY"
    /// iOS 变体（Android `FGS_BLOCKED`）：拿不到 / 被收回执行时间。下一次触发照常再申请。
    case executionBlocked = "EXECUTION_BLOCKED"
    case desktopUnreachable = "DESKTOP_UNREACHABLE"
    case desktopStorageFull = "DESKTOP_STORAGE_FULL"
    case desktopLibraryUnavailable = "DESKTOP_LIBRARY_UNAVAILABLE"
    case desktopStorageError = "DESKTOP_STORAGE_ERROR"
    /// #762：手机这边一轮跑到一半抛了没分类的异常。按偶发处理：退避探测重试。
    case unexpectedError = "UNEXPECTED_ERROR"
    /// iOS 新增（#311 D4）：iCloud 优化存储下原图不在本机，拉取因网络失败——不计失败预算，等网络 / 探测梯。
    case originalUnavailable = "ORIGINAL_UNAVAILABLE"
    /// iOS 新增（#911）：手机自己存储空间不足，取原图的临时文件写不下——不是这张照片的问题（换一张照样写不下），
    /// 不计失败预算，整体等空间释放（与 D4 网络原因同一类处置）。
    case localStorageFull = "LOCAL_STORAGE_FULL"
}

/// 执行租约受阻的原因（只给 UI 说人话，**不是闸门**）。
public enum LeaseBlockReason: String, Codable, Sendable {
    /// 在跑时被系统收回（后台时间到期）。
    case expired = "EXPIRED"
    /// 这一轮没拿到（App 不在前台、系统不给后台时间）。
    case refused = "REFUSED"
}

/// 意图（暂停标志）与等待原因的持久存储。
public protocol FlowControl: AnyObject, Sendable {
    func paused() -> Bool
    func setPaused(_ paused: Bool)
    func waitReason() -> WaitReason?
    func setWaitReason(_ reason: WaitReason?)
    func leaseBlock() -> LeaseBlockReason?
    func recordLeaseBlock(_ reason: LeaseBlockReason)
    func clearLeaseBlock()
    /// #762：这次故障的退避探测已经排过（落盘；只在成功时清）。
    func retryLadderSpent() -> Bool
    func setRetryLadderSpent(_ spent: Bool)
    /// MOB-100：「已跳过 N 张…」横幅的确认水位（ms）。
    func missingSourceAckAt() -> Int64
    func setMissingSourceAckAt(_ atMs: Int64)
}

/// [FlowControl] 的文件实现：单个小 JSON，读一次缓存。
/// **写盘失败不变成崩溃**（这条路径多半本来就在处理别的失败）：内存里的事实照样生效，记一行日志（Android 同款）。
public final class FlowControlStore: FlowControl, @unchecked Sendable {
    public static let fileName = "flow-control.json"
    private let url: URL
    private let logger: CoreLogger
    private let clock: @Sendable () -> Int64
    private let lock = NSLock()
    private var cached: State?

    struct State: Codable, Equatable {
        var paused = false
        /// [WaitReason] 的 rawValue；空 = 没在等。
        var waitReason = ""
        /// [LeaseBlockReason] 的 rawValue；空 = 没有受阻。
        var leaseBlocked = ""
        var leaseBlockedAtMs: Int64 = 0
        var missingSourceAckAtMs: Int64 = 0
        var retryLadderSpent = false

        init() {}

        enum CodingKeys: String, CodingKey { case paused, waitReason, leaseBlocked, leaseBlockedAtMs, missingSourceAckAtMs, retryLadderSpent }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            paused = try c.value(.paused, default: false)
            waitReason = try c.value(.waitReason, default: "")
            leaseBlocked = try c.value(.leaseBlocked, default: "")
            leaseBlockedAtMs = try c.value(.leaseBlockedAtMs, default: 0)
            missingSourceAckAtMs = try c.value(.missingSourceAckAtMs, default: 0)
            retryLadderSpent = try c.value(.retryLadderSpent, default: false)
        }
    }

    public init(directory: URL, logger: CoreLogger = NoopLogger(), clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
        self.clock = clock
    }

    private func load() -> State {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let s = JSONFile.read(State.self, url, logger: logger) ?? State()
        cached = s
        return s
    }

    private func update(_ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var next = cached ?? JSONFile.read(State.self, url, logger: logger) ?? State()
        change(&next)
        cached = next
        do {
            try JSONFile.write(next, url)
        } catch {
            logger.log("flow-control: write failed (\(error.localizedDescription)); keeping the in-memory value")
        }
    }

    public func paused() -> Bool { load().paused }

    public func setPaused(_ paused: Bool) { update { $0.paused = paused } }

    public func waitReason() -> WaitReason? { WaitReason(rawValue: load().waitReason) }

    public func setWaitReason(_ reason: WaitReason?) {
        let raw = reason?.rawValue ?? ""
        if load().waitReason != raw { update { $0.waitReason = raw } }
    }

    public func leaseBlock() -> LeaseBlockReason? { LeaseBlockReason(rawValue: load().leaseBlocked) }

    public func recordLeaseBlock(_ reason: LeaseBlockReason) {
        let now = clock()
        // 已经受阻时不覆盖：能说清原因的那条不被随后说不清的冲掉（UI-19 的教训）。
        update { if $0.leaseBlocked.isEmpty { $0.leaseBlocked = reason.rawValue; $0.leaseBlockedAtMs = now } }
    }

    public func clearLeaseBlock() {
        if !load().leaseBlocked.isEmpty { update { $0.leaseBlocked = ""; $0.leaseBlockedAtMs = 0 } }
    }

    public func retryLadderSpent() -> Bool { load().retryLadderSpent }

    public func setRetryLadderSpent(_ spent: Bool) {
        if load().retryLadderSpent != spent { update { $0.retryLadderSpent = spent } }
    }

    public func missingSourceAckAt() -> Int64 { load().missingSourceAckAtMs }

    public func setMissingSourceAckAt(_ atMs: Int64) { update { $0.missingSourceAckAtMs = atMs } }
}
