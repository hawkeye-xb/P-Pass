// #981：失败通知的触发集合与去重，对位 Android `DefinitiveEventNotices.kt`（#130 第 1 层）。
//
// 只发「确定、不会自愈、用户能处理」的三类事件：
// 1. 配对失效：桌面明确不认这台手机。去重键是配对代号（pairingId）；只有「没配对了」或「换了代号（重新扫码）」才复位。
// 2. 相册权限变差（完整 → 部分 / 无，部分 → 无）：记上次看到的档位，变差才发，回到完整复位；没有基线只记不发。
// 3. 后台被停：iOS 的对位物是「后台 App 刷新」从可用变成不可用（Android 的对位是电池优化被重新打开），
//    且用户要后台备份（`AutoBackupPrefs.requested()`）时才发；没有基线只记不发。
//
// 「备份出问题」（单张 / 整体失败、Trouble）**不发**：Android 因 #418（失败分类刚落地，多半误报或会自愈）故意不发。
// Android 的另一半「后台中断」（MOB-28：同一次开机内监听凭空消失 = force-stop / OEM 清理）iOS 没有对位物，
// 登记在 docs/design/2026-08-29-arch01-backup-core/06-ios-variants.zh-CN.md。
//
// 去重状态落盘（`definitive_notices.json`，文件名与字段同 Android）：每次后台任务拉起的都是新进程，只放内存会每次重发。
//
// 开关 / 系统授权只挡「发出去」这一步（`deliverable`），状态照常往前走（与 Android 一致）：
// 否则开关关着 / 未授权时发生过的事，会在用户打开开关或授权那一刻一起补发。
import Foundation

/// 三类确定事件；每类一个通知标识（后发的替换先发的，恢复时按它撤）。
public enum NoticeEvent: String, CaseIterable, Sendable {
    case pairingLost = "pairing_lost"
    case mediaAccessRevoked = "media_access_revoked"
    case backgroundStopped = "background_stopped"

    public var notificationIdentifier: String { "ppass.\(rawValue)" }
}

/// 相册权限三档（Android `MediaAccess`）。iOS 的 denied / restricted / notDetermined 都归 `.none`，与首页同口径。
public enum MediaAccessTier: String, Sendable {
    case full, partial, none

    fileprivate var rank: Int {
        switch self {
        case .full: return 2
        case .partial: return 1
        case .none: return 0
        }
    }
}

/// 一条要发的通知：事件 + 文案需要的那一点事实。
public enum NoticeKind: Equatable, Sendable {
    case pairingLost
    /// [now] 是降到的那一档（部分或无）。
    case mediaAccessRevoked(now: MediaAccessTier)
    /// [restricted]：被屏幕使用时间 / 设备管理限制，用户自己打不开（文案不同）。
    case backgroundRefreshOff(restricted: Bool)

    public var event: NoticeEvent {
        switch self {
        case .pairingLost: return .pairingLost
        case .mediaAccessRevoked: return .mediaAccessRevoked
        case .backgroundRefreshOff: return .backgroundStopped
        }
    }
}

/// 这一次运行看到的事实（App 层查出来，纯函数只读它）。
public struct DefinitiveFacts: Equatable, Sendable {
    /// 当前配对的代号；nil = 没有配对。
    public var pairingId: String?
    /// 当前配对被桌面明确拒绝过。
    public var pairingLost: Bool
    public var mediaAccess: MediaAccessTier
    /// 用户要后台备份（意图，不是此刻排没排上）。
    public var backgroundRequested: Bool
    public var backgroundRefresh: BackgroundRefreshAvailability

    public init(pairingId: String?, pairingLost: Bool, mediaAccess: MediaAccessTier, backgroundRequested: Bool, backgroundRefresh: BackgroundRefreshAvailability) {
        self.pairingId = pairingId
        self.pairingLost = pairingLost
        self.mediaAccess = mediaAccess
        self.backgroundRequested = backgroundRequested
        self.backgroundRefresh = backgroundRefresh
    }
}

/// 落盘的上一次状态（字段名同 Android；`lastBackgroundRefreshAvailable` 对位 `lastBatteryWhitelisted`）。
public struct DefinitiveNoticeState: Codable, Equatable, Sendable {
    /// 已为哪个配对代号发过「配对失效」。
    public var notifiedLostPairingId: String?
    /// 上次看到的相册权限档位（`MediaAccessTier.rawValue`）；nil = 从没记过。
    public var lastMediaAccess: String?
    /// 上次看到的「后台 App 刷新」是否可用；nil = 从没记过。
    public var lastBackgroundRefreshAvailable: Bool?

    public init(notifiedLostPairingId: String? = nil, lastMediaAccess: String? = nil, lastBackgroundRefreshAvailable: Bool? = nil) {
        self.notifiedLostPairingId = notifiedLostPairingId
        self.lastMediaAccess = lastMediaAccess
        self.lastBackgroundRefreshAvailable = lastBackgroundRefreshAvailable
    }
}

public struct DefinitiveDecision: Equatable, Sendable {
    public var next: DefinitiveNoticeState
    public var post: [NoticeKind]
    /// 已恢复的事件：撤掉还挂着的旧通知。
    public var cancel: Set<NoticeEvent>
    /// 该发但此刻发不出去（开关关 / 系统未授权）的事件：不在 [post] 里（状态仍已推进）。App 层据此记日志。
    public var undeliverable: [NoticeEvent]
}

/// 纯判定：上一次的状态 + 这一次的事实 → 新状态、要发的、要撤的。
public func decideDefinitiveNotices(prev: DefinitiveNoticeState, facts: DefinitiveFacts, deliverable: Bool) -> DefinitiveDecision {
    var post: [NoticeKind] = []
    var cancel: Set<NoticeEvent> = []
    let paired = facts.pairingId != nil

    // 1. 配对失效：键是 pairingId。没配对 / 换了代号才复位；lost 变 false（进程重启）不算恢复。
    var notifiedLostPairingId = prev.notifiedLostPairingId
    if let notified = notifiedLostPairingId, notified != facts.pairingId {
        notifiedLostPairingId = nil
        cancel.insert(.pairingLost)
    }
    if paired, facts.pairingLost, notifiedLostPairingId != facts.pairingId {
        post.append(.pairingLost)
        notifiedLostPairingId = facts.pairingId
        cancel.remove(.pairingLost)
    }

    // 2. 相册权限：变差才发，回到完整复位；没有基线只记不发；没配对时只记。
    let lastAccess = prev.lastMediaAccess.flatMap(MediaAccessTier.init(rawValue:))
    if let last = lastAccess, facts.mediaAccess.rank < last.rank, paired {
        post.append(.mediaAccessRevoked(now: facts.mediaAccess))
    }
    if let last = lastAccess, last != .full, facts.mediaAccess == .full {
        cancel.insert(.mediaAccessRevoked)
    }

    // 3. 后台被停：「后台 App 刷新」只在 可用 → 不可用 且用户要后台备份时发；没有基线只记不发。
    let available = facts.backgroundRefresh == .available
    if paired, prev.lastBackgroundRefreshAvailable == true, !available, facts.backgroundRequested {
        post.append(.backgroundRefreshOff(restricted: facts.backgroundRefresh == .restricted))
    }
    let wasStopped = prev.lastBackgroundRefreshAvailable == false
    let isStopped = !available && facts.backgroundRequested
    if wasStopped, !isStopped { cancel.insert(.backgroundStopped) }

    let next = DefinitiveNoticeState(notifiedLostPairingId: notifiedLostPairingId, lastMediaAccess: facts.mediaAccess.rawValue,
                                     lastBackgroundRefreshAvailable: available)

    // 发不出去（开关关 / 系统未授权）：只是不发，状态照常推进，之后打开也不补发。
    var undeliverable: [NoticeEvent] = []
    if !deliverable {
        undeliverable = post.map(\.event)
        post = []
    }
    return DefinitiveDecision(next: next, post: post, cancel: cancel, undeliverable: undeliverable)
}

/// 落盘（`JSONFile`：整文件原子替换）。
public final class DefinitiveNoticeStore: @unchecked Sendable {
    public static let fileName = "definitive_notices.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    /// 缺失 = 全新基线（不记日志）；损坏 = 同样回到基线（Android 同），但要留一行日志。
    public func load() -> DefinitiveNoticeState {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return DefinitiveNoticeState() }
        return JSONFile.read(DefinitiveNoticeState.self, url, logger: logger) ?? DefinitiveNoticeState()
    }

    public func save(_ state: DefinitiveNoticeState) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try JSONFile.write(state, url)
    }
}

public enum DefinitiveEventMonitor {
    /// 评估入口：读状态 → 判定 → **先落盘**（失败抛出，不吞）→ 由调用方发 / 撤。进程内串行。
    public static func evaluate(store: DefinitiveNoticeStore, facts: DefinitiveFacts, deliverable: Bool) throws -> DefinitiveDecision {
        lock.lock(); defer { lock.unlock() }
        let decision = decideDefinitiveNotices(prev: store.load(), facts: facts, deliverable: deliverable)
        try store.save(decision.next)
        return decision
    }

    private static let lock = NSLock()
}
