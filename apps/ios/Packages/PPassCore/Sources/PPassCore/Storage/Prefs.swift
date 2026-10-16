// #338：意图与偏好的小文件 store，逐个对位 Android（apps/android/.../backup/）。
// 文件名、字段名、默认值、损坏时的处置照 Android **代码**（不照注释）：
//
// | iOS                       | Android 对位                 | 文件                          | 损坏 / 缺失时             |
// |---------------------------|-----------------------------|-------------------------------|--------------------------|
// | AutoBackupPrefs           | AutoBackupPrefs.kt          | auto_backup_prefs.json        | autoEnabled=false，userRequested=nil |
// | BackupSettings            | BackupSettings.kt           | backup-settings.json          | wifiOnly=true            |
// | NotifyOnFailurePrefs      | NotifyOnFailurePrefs.kt     | notify_on_failure_prefs.json  | enabled=true             |
// | OnboardingNotificationAsk | OnboardingNotificationAsk.kt | onboarding_notification_ask.json | 缺失=不问，损坏=已问过 |
// | OnboardedDesktopsStore    | OnboardedDesktopsStore.kt   | onboarded_desktops.json       | 空集（失败关闭：按新电脑走） |
// | SentinelStore             | SentinelStore.kt            | sentinel.json                 | 全 0                     |
// | BackupScopeStore          | BackupScopeStore.kt         | backup_scope[-<nodeId>].json  | nil（= 一张都不在范围内）  |
//
// 不移植（Android 已退役，见 DisconnectStateManifest 的 RETIRED 行）：PausePrefs、ConfirmedStore、HashCache、
// ReuploadQueue、WatermarkStore、BackupAttemptStore、WhitelistNudgeStore。暂停标志在 [FlowControlStore]。
import Foundation

// MARK: - AutoBackupPrefs

/// 自动备份开关：只拥有「是否允许自动唤醒」这一条策略事实（MOB-65）。
/// [enabled] 是生产者的实际状态；[requested] 是用户的明确意图——断开时停生产者、留意图（MOB-93）。
public final class AutoBackupPrefs: @unchecked Sendable {
    public static let fileName = "auto_backup_prefs.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    private struct State: Codable {
        var autoEnabled: Bool
        var userRequested: Bool?
    }

    private func load() -> State {
        guard let fields = JSONFile.readObject(url, logger: logger) else { return State(autoEnabled: false, userRequested: nil) }
        // 旧文件只有 `paused`：autoEnabled = !paused（Android 同款回退）。
        let enabled = fields.bool("autoEnabled") ?? fields.bool("paused").map { !$0 } ?? false
        return State(autoEnabled: enabled, userRequested: fields.bool("userRequested"))
    }

    public func enabled() -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return load().autoEnabled
    }

    /// 用户意图；旧文件没有这个键时退回当时的生产者状态。
    public func requested() -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        let s = load()
        return s.userRequested ?? s.autoEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        var s = load()
        s.autoEnabled = enabled
        try JSONFile.write(s, url)
    }

    public func setRequested(_ requested: Bool) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        var s = load()
        s.userRequested = requested
        try JSONFile.write(s, url)
    }

    /// MOB-93：断开 / 配对变化——**停生产者，留意图**（对位 `suspendAutoBackupForPairingChange`）。
    public func suspendForPairingChange() throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try setRequested(requested())
        try setEnabled(false)
    }
}

/// 快速重连后按留下的意图恢复自动备份（对位 `autoBackupResumeDecision`）。
public enum AutoBackupResume: Equatable, Sendable {
    case enable, suspend, leaveOff

    /// [backgroundAuthorized]：后台执行的前提（Android 是电池白名单；iOS 是「后台 App 刷新」）。
    public static func decide(userRequested: Bool, backgroundAuthorized: Bool) -> AutoBackupResume {
        if !userRequested { return .leaveOff }
        return backgroundAuthorized ? .enable : .suspend
    }
}

// MARK: - BackupSettings

/// 自动备份的极简设置：仅 Wi‑Fi（UX-03；MOB-10 删掉了「仅充电」，旧文件里的 chargeOnly 忽略）。
public final class BackupSettings: @unchecked Sendable {
    public static let fileName = "backup-settings.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    private struct State: Codable { var wifiOnly: Bool = true }

    public func wifiOnly() -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        guard let fields = JSONFile.readObject(url, logger: logger) else { return true }
        return fields.bool("wifiOnly") ?? true
    }

    public func save(wifiOnly: Bool) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try JSONFile.write(State(wifiOnly: wifiOnly), url)
    }
}

// MARK: - NotifyOnFailurePrefs

/// 设置页「需要处理时通知我」（#130）。默认开。
public final class NotifyOnFailurePrefs: @unchecked Sendable {
    public static let fileName = "notify_on_failure_prefs.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    private struct State: Codable { var enabled: Bool }

    public func enabled() -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        guard let fields = JSONFile.readObject(url, logger: logger) else { return true }
        return fields.bool("enabled") ?? true
    }

    public func setEnabled(_ enabled: Bool) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try JSONFile.write(State(enabled: enabled), url)
    }
}

// MARK: - OnboardedDesktopsStore

/// 「这台电脑以前连过吗」的唯一事实来源（MOB-114）。只增不减；断开、配对失效都不碰。
/// 损坏 = 空集 = 按新电脑走 onboarding：宁可多问一次，不许把新电脑当旧电脑静默继承后台备份意图。
public final class OnboardedDesktopsStore: @unchecked Sendable {
    public static let fileName = "onboarded_desktops.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    private struct State: Codable { var nodeIds: [String] }

    private func load() -> Set<String> {
        Set(JSONFile.read(State.self, url, logger: logger)?.nodeIds ?? [])
    }

    public func wasOnboarded(_ daemonNodeId: String) -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return !daemonNodeId.isBlank && load().contains(daemonNodeId)
    }

    /// 这台手机是否走完过任何一次 onboarding。
    public func anyOnboarded() -> Bool {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return !load().isEmpty
    }

    public func markOnboarded(_ daemonNodeId: String) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        guard !daemonNodeId.isBlank else { return }
        var ids = load()
        guard ids.insert(daemonNodeId).inserted else { return }
        try JSONFile.write(State(nodeIds: ids.sorted()), url)
    }
}

/// 连回的是不是以前连过的那台：走完过 onboarding，**并且这台**桌面的相册范围还在（MOB-92）。
/// [scopeNonEmpty] 惰性：标记不在就不读范围（读范围会触发一次性认领）。
public func isKnownDesktop(_ store: OnboardedDesktopsStore, daemonNodeId: String, scopeNonEmpty: () -> Bool) -> Bool {
    store.wasOnboarded(daemonNodeId) && scopeNonEmpty()
}

// MARK: - SentinelStore

/// SENT-01：「3 天没连上电脑」哨兵——搭现有任务便车记可达性，不是后台心跳。
public struct SentinelState: Codable, Equatable, Sendable {
    public var lastReachableAt: Int64 = 0
    public var failedAttempts: Int = 0
    public var lastNotifiedAt: Int64 = 0

    public init(lastReachableAt: Int64 = 0, failedAttempts: Int = 0, lastNotifiedAt: Int64 = 0) {
        self.lastReachableAt = lastReachableAt
        self.failedAttempts = failedAttempts
        self.lastNotifiedAt = lastNotifiedAt
    }

    enum CodingKeys: String, CodingKey { case lastReachableAt, failedAttempts, lastNotifiedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastReachableAt = try c.value(.lastReachableAt, default: 0)
        failedAttempts = try c.value(.failedAttempts, default: 0)
        lastNotifiedAt = try c.value(.lastNotifiedAt, default: 0)
    }
}

public enum Sentinel {
    public static let thresholdMs: Int64 = 72 * 60 * 60 * 1000
    public static let cooldownMs: Int64 = 72 * 60 * 60 * 1000

    /// 四条全满足才提醒：确认可达过；距今超过 72h；期间有失败尝试；距上次提醒超过 72h。
    public static func shouldNotify(_ s: SentinelState, now: Int64, thresholdMs: Int64 = thresholdMs, cooldownMs: Int64 = cooldownMs) -> Bool {
        guard s.lastReachableAt > 0 else { return false }
        guard now - s.lastReachableAt > thresholdMs else { return false }
        guard s.failedAttempts >= 1 else { return false }
        return now - s.lastNotifiedAt > cooldownMs
    }
}

public final class SentinelStore: @unchecked Sendable {
    public static let fileName = "sentinel.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    public func load() -> SentinelState {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return JSONFile.read(SentinelState.self, url, logger: logger) ?? SentinelState()
    }

    private func update(_ change: (inout SentinelState) -> Void) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        var s = load()
        change(&s)
        try JSONFile.write(s, url)
    }

    /// 确认可达：记时间、失败计数清零。
    public func recordReachable(now: Int64) throws { try update { $0.lastReachableAt = now; $0.failedAttempts = 0 } }

    /// 一次失败尝试（可达时间不动）。
    public func recordUnreachable() throws { try update { $0.failedAttempts += 1 } }

    public func markNotified(now: Int64) throws { try update { $0.lastNotifiedAt = now } }
}

// MARK: - BackupScopeStore

/// 备份范围（选了哪些相册）——**每台桌面一份**（MOB-92）。相册 id 是 PHAssetCollection 的 localIdentifier。
///
/// 未配对（nodeId 为空）时读写全局那一份 `backup_scope.json`；第一台来取范围的桌面**复制**认领它一次并盖章，
/// 之后连上的新桌面不再继承（Android `decideAdoption` 的同一判据）。
public final class BackupScopeStore: @unchecked Sendable {
    public static let legacyName = "backup_scope"
    private let directory: URL
    private let nodeId: String?
    private let logger: CoreLogger

    public init(directory: URL, daemonNodeId: String?, logger: CoreLogger = NoopLogger()) {
        self.directory = directory
        self.nodeId = daemonNodeId.flatMap { $0.isBlank ? nil : $0 }
        self.logger = logger
    }

    public static func fileName(nodeId: String?) -> String {
        guard let id = nodeId, !id.isBlank else { return "\(legacyName).json" }
        return "\(legacyName)-\(id).json"
    }

    public enum Adoption: Equatable, Sendable { case alreadyClaimed, copyThenStamp, stampOnly }

    /// 全局那一份该不该归给当前这台。纯函数。
    public static func decideAdoption(alreadyAdoptedBy: String?, legacyBuckets: [String]?) -> Adoption {
        if let by = alreadyAdoptedBy, !by.isBlank { return .alreadyClaimed }
        guard let buckets = legacyBuckets else { return .stampOnly }
        return buckets.isEmpty ? .stampOnly : .copyThenStamp
    }

    private struct State: Codable {
        var bucketIds: [String]?
        var knownBucketIds: [String]?
        var adoptedBy: String?

        enum CodingKeys: String, CodingKey { case bucketIds = "bucket_ids", knownBucketIds = "known_bucket_ids", adoptedBy = "adopted_by" }
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName(nodeId: nodeId)) }

    private func load(_ url: URL) -> State {
        JSONFile.read(State.self, url, logger: logger) ?? State()
    }

    private func adoptLegacyOnce() throws {
        guard let id = nodeId else { return }
        let legacyURL = directory.appendingPathComponent(Self.fileName(nodeId: nil))
        var legacy = load(legacyURL)
        switch Self.decideAdoption(alreadyAdoptedBy: legacy.adoptedBy, legacyBuckets: legacy.bucketIds) {
        case .alreadyClaimed:
            return
        case .stampOnly:
            break
        case .copyThenStamp:
            // 复制不是移动：全局那份原样留着，判断错了还能追溯。
            try JSONFile.write(State(bucketIds: legacy.bucketIds, knownBucketIds: legacy.knownBucketIds), url)
        }
        legacy.adoptedBy = id
        try JSONFile.write(legacy, legacyURL)
    }

    private func current() throws -> State {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try adoptLegacyOnce()
        return load(url)
    }

    /// 选中的相册。nil = 从未保存过范围——**不是**「全部」：引擎把 nil 与空集都当成一张都不在范围内（MOB-40）。
    public func selectedBucketIds() throws -> Set<String>? {
        try current().bucketIds.map(Set.init)
    }

    /// MOB-02：最近一次保存范围时看到的全部相册；不在里面的相册在选择页标「新」、默认不勾。
    public func knownBucketIds() throws -> Set<String>? {
        try current().knownBucketIds.map(Set.init)
    }

    public func saveScope(selected: Set<String>, allCurrent: Set<String>) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try adoptLegacyOnce()
        var s = load(url)
        s.bucketIds = selected.sorted()
        s.knownBucketIds = allCurrent.sorted()
        try JSONFile.write(s, url)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
