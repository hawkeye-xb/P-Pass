// #413 三层模型的「事实」层与「意图」层的跳过名单（对位 Android `order/OrderStore.kt`）。
//   意图（相册范围、跳过名单、暂停标志）—— 只有用户操作写；范围在 BackupScopeStore，暂停在 FlowControl，跳过名单在这里。
//   事实（order：一次传输一行）—— 只有执行循环与对账写。
//   待办 —— 不存；现算 = 范围内照片 − 跳过名单 − 已有结局（见 FlowEngine 的计数）。
//
// 与 Android 的差异（登记在 iOS 变体文档）：
//   - 媒体身份是字符串（PHAsset.localIdentifier），相册身份也是字符串；两路归并一律按 **UTF-8 字节序**（= SQLite BINARY）。
//   - 发现游标 G 不是 (generation, `_id`)，而是一个**不透明位置**（PHPersistentChangeToken + 批内进度），只有一个照片库，
//     没有多卷；推进 = 覆盖写，单调性由引擎保证（不能像 Android 那样在 SQL 里取 max）。
//   - 没有 `location_redacted`（#843/#851）：PhotoKit 给的原始资源不抹地点。
import Foundation

/// 一条 order（一次传输）的状态。持久化存 rawValue，**不许改名**。
public enum OrderState: String, CaseIterable, Codable, Sendable {
    /// 待传输：桌面缺失的补传、在飞时相册被移出范围的行、用户点「重试」的失败行。
    case pending = "PENDING"
    /// 传输中。中断（暂停、执行时间被收回、断网、进程被杀）后保持不变，下一轮按「遗留续传」最先取。
    case transferring = "TRANSFERRING"
    case confirmed = "CONFIRMED"
    /// 单张失败。兜底对账重试到 [OrderStoreLimits.maxFailures] 次为止。
    case failed = "FAILED"
    /// 用户取消剩余时这一张正在传 / 待传。
    case skippedByUser = "SKIPPED_BY_USER"
    /// 原图没了，或这一行记的版本已经不存在（中断期间被编辑）。不计失败。
    case skippedSourceMissing = "SKIPPED_SOURCE_MISSING"

    /// 还没有结局、取消剩余可以覆盖的状态。
    public var isOpen: Bool { self == .pending || self == .transferring || self == .failed }

    /// 对同一版本的照片来说已有结局：不再是待办。
    public var isSettled: Bool { self == .confirmed || self == .skippedSourceMissing }

    public static let open: Set<OrderState> = Set(allCases.filter(\.isOpen))
}

public enum OrderStoreLimits {
    /// 同一行最多失败几次（当场重试 1 次 + 兜底对账 1 次，#413 裁定 6）；到了之后保持失败，只有用户点「重试」再来。
    public static let maxFailures = 2
}

/// 媒体身份的排序：UTF-8 字节序（与 SQLite 默认的 BINARY 排序一致）。Swift 的 `String <` 按 Unicode 规范等价比较，
/// 两者在组合字符上会分歧——所有两路归并都必须走这一个函数。
public enum MediaOrder {
    public static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}

/// 一行 order。[id] 永不复用，填进协议的 `queue_sequence`（`lease_token` = `lease-<id>`）。
/// 同一个 [mediaId] 可以有多行；「当前」那一行是该 media_id 下 id 最大的那行。
public struct Order: Equatable, Sendable {
    public let id: Int64
    public let mediaId: String
    /// 内容版本（只看内容变没变：修改时间 + 大小，见 `sourceVersionOf`）。
    public let sourceVersion: String
    public let bucketId: String
    /// BLAKE3 hex；导入之前为 nil。
    public var contentHash: String?
    public let state: OrderState
    /// 失败次数（每记一次 FAILED 加 1；当场重试那一次不单独算）。
    public let attempts: Int
    /// 建这行时的配对代号（防护列，#415 裁决 6）。
    public let pairingEpoch: String
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    /// 照片库里已经没有这张的原图。CONFIRMED 不改写，只打这个标记（#416 裁决 2 / #459）。
    public let sourceMissing: Bool
}

public struct NewOrder: Equatable, Sendable {
    public let mediaId: String
    public let sourceVersion: String
    public let bucketId: String
    public let contentHash: String?
    public let state: OrderState
    public let pairingEpoch: String

    public init(mediaId: String, sourceVersion: String, bucketId: String, contentHash: String?, state: OrderState, pairingEpoch: String) {
        precondition(!mediaId.isEmpty, "mediaId must not be empty")
        precondition(!sourceVersion.isBlank, "sourceVersion must not be blank")
        precondition(contentHash == nil || !contentHash!.isBlank, "contentHash must be nil or non-blank")
        self.mediaId = mediaId
        self.sourceVersion = sourceVersion
        self.bucketId = bucketId
        self.contentHash = contentHash
        self.state = state
        self.pairingEpoch = pairingEpoch
    }
}

/// 「取消剩余」边界里的一张：弹窗那一刻它还是待办。
public struct SkipTarget: Equatable, Hashable, Sendable {
    public let mediaId: String
    public let sourceVersion: String
    public let bucketId: String

    public init(mediaId: String, sourceVersion: String, bucketId: String) {
        precondition(!sourceVersion.isBlank, "sourceVersion must not be blank")
        self.mediaId = mediaId
        self.sourceVersion = sourceVersion
        self.bucketId = bucketId
    }
}

/// 写进跳过名单几张、其中几张的在途 order 改成用户跳过、几张弹窗之后已有结局（未动）。
public struct SkipResult: Equatable, Sendable {
    public let written: Int
    public let ordersSkipped: Int
    public let untouched: Int
}

/// 发现游标 G：媒体源给出的不透明位置（iOS 上 = PHPersistentChangeToken + 批内进度，由 PPassMedia 编码）。
/// 核心只存、只比较相等，从不解释它的字节。
public struct DiscoveryPosition: Equatable, Hashable, Codable, Sendable {
    public let raw: Data

    public init(raw: Data) { self.raw = raw }
}

/// 照片库的游标状态（对位 Android `VolumeState`，只有一个库）。
public struct DiscoveryState: Equatable, Sendable {
    /// 已处理到的位置：之后的变化才是「新照片」。
    public let position: DiscoveryPosition
    /// 上次看到的照片库身份（媒体源给出；变了 = 库被重建 / 换了，G 重置、扫描置脏）。
    public let libraryIdentity: String?

    public init(position: DiscoveryPosition, libraryIdentity: String?) {
        self.position = position
        self.libraryIdentity = libraryIdentity
    }
}

/// 对账扫描游标 S（按媒体 id 字节序升序）。[dirty] 时扫描才是取件来源；[cursor] 为 nil = 从头。
public struct ScanState: Equatable, Sendable {
    public let dirty: Bool
    public let cursor: String?

    public init(dirty: Bool, cursor: String?) {
        self.dirty = dirty
        self.cursor = cursor
    }
}

/// AUDIT-01 的持久 outbox 事件：与它描述的事实**同一个事务**落库。
public struct AuditRecord: Equatable, Sendable {
    public let eventId: String
    public let kind: String
    public let roundId: String?
    public let occurredAtMs: Int64
    public let payload: [String: String]

    public init(eventId: String, kind: String, roundId: String?, occurredAtMs: Int64, payload: [String: String]) {
        self.eventId = eventId
        self.kind = kind
        self.roundId = roundId
        self.occurredAtMs = occurredAtMs
        self.payload = payload
    }

    /// 线上形状（`flow.audit.submit` 的一项）。
    public var wire: FlowAuditEvent {
        FlowAuditEvent(eventId: eventId, kind: kind, roundId: roundId, occurredAtMs: occurredAtMs, payload: payload)
    }
}

public struct SequencedAudit: Equatable, Sendable {
    public let seq: Int64
    public let record: AuditRecord
}

/// MOB-98：一张照片的「版本」只由内容变没变决定（修改时间 + 大小）。
public func sourceVersionOf(modifiedAtMs: Int64, size: Int64) -> String { "\(modifiedAtMs):\(size)" }
