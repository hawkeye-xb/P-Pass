// #891：逐张循环的核心类型与端口（对位 Android `flow/FlowContract.kt` + `flow/FlowCore.kt`）。本文件不碰任何平台 API。
//
// 模型（#413 最终设计）：三层——意图（范围、跳过名单、暂停标志）/ 事实（order：一次传输一行）/ 待办（现算）。
// 触发只叫醒循环 → 入口检查（不持有执行租约、不读文件）→ 申请执行租约 + 一条推送订阅 →
// 取件（遗留续传 → 对账扫描 → 新照片 → 对账补传）→ 准备 → 传输 → 提交 → 下一张 → 释放。
//
// 平台依赖全部是 protocol：媒体源（PhotoKit，#314/#335）、导入 / 哈希（PhotoKit 取字节 + FFI BLAKE3，#337/#313）、
// 传输（FFI，#313）、桌面探测、执行租约（前台 / 后台任务时间）、唤醒登记（BGTaskScheduler，#340）、时钟、日志。
import Foundation

/// 全局状态。暂停是全局的，不是 order 的状态。
public enum GlobalState: String, Sendable {
    case idle = "IDLE"
    case running = "RUNNING"
    /// 只有用户能解除。
    case paused = "PAUSED"
    /// 条件不满足 / 桌面不可达或不健康，由我们自动恢复；原因见 [EngineView.waitReason]。
    case waiting = "WAITING"
}

/// 探测时桌面带回的健康状况（领域类型；线上形状是 [DesktopHealthWire]）。旧版桌面不报时为 nil（视为健康）。
public struct DesktopHealth: Equatable, Sendable {
    public var freeBytes: Int64?
    public var libraryWritable: Bool
    public var indexOk: Bool

    public init(freeBytes: Int64?, libraryWritable: Bool = true, indexOk: Bool = true) {
        self.freeBytes = freeBytes
        self.libraryWritable = libraryWritable
        self.indexOk = indexOk
    }

    public init(wire: DesktopHealthWire) {
        self.init(freeBytes: wire.freeBytes, libraryWritable: wire.libraryWritable, indexOk: wire.indexOk)
    }

    public static let lowSpaceBytes: Int64 = 5 * 1024 * 1024 * 1024
    /// 与 daemon 的 `SPACE_RESERVE_BYTES`（crates/daemon/src/flow_delivery.rs）同值（#555）。
    public static let criticallyLowBytes: Int64 = 256 * 1024 * 1024

    public var lowSpace: Bool { freeBytes.map { $0 < Self.lowSpaceBytes } ?? false }
    public var criticallyLow: Bool { freeBytes.map { $0 < Self.criticallyLowBytes } ?? false }
}

/// 对端失败的具体原因：桌面自身的问题，不计入这张照片的失败次数。
public enum PeerFailureKind: String, Sendable {
    case storageFull = "STORAGE_FULL"
    case libraryUnavailable = "LIBRARY_UNAVAILABLE"
    case storageError = "STORAGE_ERROR"
}

public func waitReasonOf(_ kind: PeerFailureKind) -> WaitReason {
    switch kind {
    case .storageFull: return .desktopStorageFull
    case .libraryUnavailable: return .desktopLibraryUnavailable
    case .storageError: return .desktopStorageError
    }
}

/// 探测带回的桌面健康 → 不健康时的等待原因；nil = 健康（旧桌面不报也算健康）。低空间只是预警，不挡。
public func waitReasonOf(_ health: DesktopHealth?) -> WaitReason? {
    guard let health else { return nil }
    if !health.libraryWritable && health.criticallyLow { return .desktopStorageFull }
    if !health.libraryWritable { return .desktopLibraryUnavailable }
    if !health.indexOk { return .desktopStorageError }
    return nil
}

/// 一次检查所需的全部条件事实。由平台层实时读取，这里只做判断。
public struct Conditions: Equatable, Sendable {
    public var paired: Bool
    public var autoBackupEnabled: Bool
    public var wifiOnly: Bool
    /// iOS：当前路径不是「昂贵」的（NWPath.isExpensive == false，即非蜂窝 / 非个人热点）。
    public var onUnmetered: Bool
    public var batteryLow: Bool

    public init(paired: Bool = true, autoBackupEnabled: Bool = true, wifiOnly: Bool = false, onUnmetered: Bool = true, batteryLow: Bool = false) {
        self.paired = paired
        self.autoBackupEnabled = autoBackupEnabled
        self.wifiOnly = wifiOnly
        self.onUnmetered = onUnmetered
        self.batteryLow = batteryLow
    }
}

/// 入口的条件检查（C-04 的判据本体）。暂停是更早、更硬的一道闸；桌面可达要走网络，不在这里。
public func waitReasonOf(_ c: Conditions, userPresent: Bool) -> WaitReason? {
    if !c.paired { return .notPaired }
    if !userPresent && !c.autoBackupEnabled { return .disabled }
    if c.wifiOnly && !c.onUnmetered { return .wifi }
    if !userPresent && c.batteryLow { return .battery }
    return nil
}

/// 触发原因。触发只叫醒循环（在跑就合并），只有两个维度：人在不在场、这一轮要不要对账。
public enum TriggerReason: String, CaseIterable, Sendable {
    case mediaChange = "MEDIA_CHANGE"
    case processStart = "PROCESS_START"
    case networkChange = "NETWORK_CHANGE"
    case unreachableProbe = "UNREACHABLE_PROBE"
    case constraintsMet = "CONSTRAINTS_MET"
    case periodic = "PERIODIC"
    case appForeground = "APP_FOREGROUND"
    case scopeAdded = "SCOPE_ADDED"
    case pairingRepaired = "PAIRING_REPAIRED"
    case userContinue = "USER_CONTINUE"
    case retryFailed = "RETRY_FAILED"
    case restoreSkipped = "RESTORE_SKIPPED"
    case manual = "MANUAL"
    /// App 在前台时照片库变了：人在场，不查后台开关。
    case foregroundMediaChange = "FOREGROUND_MEDIA_CHANGE"
    /// 等待中（桌面不可达）时前台心跳又连上了桌面。
    case desktopReachable = "DESKTOP_REACHABLE"

    /// 人在场（打开 App、改范围、点继续、手动）——不查后台开关、不查电量。仅 Wi‑Fi 对所有触发都生效。
    public var userPresent: Bool {
        switch self {
        case .appForeground, .scopeAdded, .pairingRepaired, .userContinue, .retryFailed, .restoreSkipped, .manual, .foregroundMediaChange, .desktopReachable:
            return true
        default:
            return false
        }
    }

    /// 这一轮在「发现」取完之后接着做「对账」：扫 G 以下、兜底重试失败项、问桌面「这些还在吗」。
    public var reconcile: Bool {
        switch self {
        case .periodic, .appForeground, .scopeAdded, .pairingRepaired, .userContinue, .retryFailed, .restoreSkipped:
            return true
        default:
            return false
        }
    }
}

/// 进入「等待中」时登记哪种唤醒。不变式：**有没传完的、当前又没在传 ⇒ 至少登记着一个会触发的唤醒**；例外只有要用户动手的。
public enum WakePlan: Equatable, Sendable {
    case awaitsUser
    case whenConditionsMet(WaitReason)
    /// 退避探测：一条 4 拍的链（10 / 20 / 40 / 80 分钟）；一次故障只排一组（[FlowControl.retryLadderSpent]）。
    case retryProbes
}

/// 等待原因 → 唤醒种类。穷举、没有 default：新增 [WaitReason] 不写映射就编译不过。
public func wakePlanOf(_ reason: WaitReason) -> WakePlan {
    switch reason {
    case .notPaired, .disabled: return .awaitsUser
    case .wifi, .battery: return .whenConditionsMet(reason)
    // iOS 变体：执行时间被收回 / 拿不到——没有 Android 的 FGS 额度窗口可算，交给探测梯（由 BGTask 尽力兑现）。
    case .executionBlocked: return .retryProbes
    case .desktopUnreachable, .desktopStorageFull, .desktopLibraryUnavailable, .desktopStorageError, .unexpectedError: return .retryProbes
    // D4：iCloud 原图因网络拉不下来——与桌面不可达同一类（网络回来时网络变化就是触发，探测梯兜底）。
    case .originalUnavailable: return .retryProbes
    // #911：空间释放没有系统事件可等；探测梯 + 回前台 / 周期兜底接住。
    case .localStorageFull: return .retryProbes
    }
}

/// `lease_token` 的线上形状：queue_sequence / lease_token 都由 order 行 id 填，线协议不改。
public func leaseTokenFor(_ orderId: Int64) -> String { "lease-\(orderId)" }

/// 桌面给出的完成凭据（已由传输端口对过字段）。
public struct CompletionReceipt: Equatable, Sendable {
    public let queueSequence: Int64
    public let receiptId: String
    public let pairingEpoch: String
    public let contentHash: String?
    public let leaseToken: String

    public init(queueSequence: Int64, receiptId: String, pairingEpoch: String, contentHash: String?, leaseToken: String) {
        self.queueSequence = queueSequence
        self.receiptId = receiptId
        self.pairingEpoch = pairingEpoch
        self.contentHash = contentHash
        self.leaseToken = leaseToken
    }
}

// MARK: - 媒体源

/// 照片库里的一张（只读元数据）。
public struct MediaSnapshot: Equatable, Sendable {
    public let mediaId: String
    /// 内容版本（[sourceVersionOf]）：只看内容变没变。
    public let sourceVersion: String
    /// 范围键：媒体源定义（iOS 上一张照片可以同时在多个相册里，PPassMedia 用它编码所属相册），由注入的 `inScope` 解释。
    public let bucketId: String
    /// 只在「发现」读出时有：处理完这一张之后 G 应该停在哪。
    public let position: DiscoveryPosition?

    public init(mediaId: String, sourceVersion: String, bucketId: String, position: DiscoveryPosition? = nil) {
        self.mediaId = mediaId
        self.sourceVersion = sourceVersion
        self.bucketId = bucketId
        self.position = position
    }
}

/// 传输一张照片需要的全部事实。
public struct MediaDetails: Equatable, Sendable {
    public let snapshot: MediaSnapshot
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int64
    /// 拍摄时刻（unix ms；0 = 不知道）。
    public let captureAtMs: Int64

    public init(snapshot: MediaSnapshot, fileName: String, mimeType: String, sizeBytes: Int64, captureAtMs: Int64) {
        self.snapshot = snapshot
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.captureAtMs = captureAtMs
    }
}

/// 发现游标已经失效（iOS：`PHPhotosErrorPersistentChangeTokenExpired` = 3105）。引擎的处置与 Android「MediaStore
/// 版本变了」同一条路：G 重置到当前位置、对账扫描置脏，已有照片交给扫描（按内容哈希去重收敛）。
public struct DiscoveryCursorExpired: Error, Equatable, Sendable {
    public init() {}
}

/// 媒体源（只读元数据、不读文件、不联系桌面）。对位 Android `MediaSnapshotSource`。
/// 长查询（几万张的 fetch）应响应 Task 取消：暂停 / 断网要尽快生效。
public protocol MediaSource: Sendable {
    /// 对账扫描 / 精确计数：**范围内**、id 按字节序大于 [after] 的照片，按 id 字节序严格升序，最多 [limit] 张。
    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot]

    /// 发现：[position] 之后新增 / 变化的**范围内**照片，按媒体源的顺序，最多 [limit] 张。每张带 `position`：
    /// 处理完这一张之后 G 应停的位置；位置沿返回顺序单调，最后一张的位置覆盖之前的全部。下一页从上一页最后一张的位置接着读。
    /// 位置已经失效时抛 [DiscoveryCursorExpired]。
    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot]

    /// 当前位置（G 缺失 / 失效 / 照片库换了时从这里起步）。
    func currentPosition() async throws -> DiscoveryPosition

    /// 照片库的身份（变了 = 重建 / 换了库）。nil = 说不出来（不触发重置）。
    func libraryIdentity() async throws -> String?

    /// 这张照片现在的样子；照片库里已经没有了返回 nil。
    func lookup(_ mediaId: String) async throws -> MediaDetails?

    /// [mediaIds] 里哪些此刻还在照片库里（**不看范围**）。nil = 读不出来（调用方当「不知道」，不许当「全都没了」）。
    func existingIds(_ mediaIds: [String]) async throws -> Set<String>?

    /// G 是否可信到「G 以下不会漏照片」。false 时每个对账轮都扫一遍范围（#904）。
    /// PhotoKit：`PHPersistentChangeToken` 不绑定图库，跨库可能不报错地错位，而 PhotoKit 没有公开的图库标识可比——
    /// 所以 PPassMedia 应当报 false，直到找到可靠的图库标识接到 [libraryIdentity]。
    var preciseDiscovery: Bool { get }
}

extension MediaSource {
    /// 默认失败关闭：说不清就当不精确（多扫一遍只费元数据读，漏照片是丢备份）。
    public var preciseDiscovery: Bool { false }
}

// MARK: - 导入（准备这一步唯一读文件的地方）

public enum ImportResult: Equatable, Sendable {
    /// 流式读一次原图，得到 BLAKE3。
    case imported(contentHash: String, sizeBytes: Int64)
    /// 照片库还列着、原图读不到（被删）。
    case sourceMissing
    /// #311 D4：iCloud 优化存储下原图不在本机，**因为网络**拉不下来——暂时性，不计失败预算。
    /// 资源确实不可得（不是网络问题）要抛错，由引擎当单张失败计次。
    case originalUnavailable(reason: String)
    /// #911：手机本地空间不足，取原图的临时文件写不下（PhotoKit 3305 / 写盘 ENOSPC）。不是这张照片的问题，
    /// 不计失败预算，整体等待。
    case localStorageFull(reason: String)
}

/// 原图 → 手机侧 iroh store（FFI）。导入与供数分两步：先拿 hash 建 order，再用这张 order 的 lease 供数。
public protocol MediaImporter: Sendable {
    /// iOS：经 PHAssetResourceManager（`isNetworkAccessAllowed = true`）取原始字节到临时目录、算哈希、导入；
    /// 临时文件由实现负责清理。只在备份轮内被调用（天然受 Wi‑Fi / 电量约束）。
    ///
    /// **取消契约**：必须响应 Task 取消——停掉进行中的下载（`cancelDataRequest`）、删掉临时文件、抛 `CancellationError`。
    /// 不响应的话，暂停 / 断网要等整段 iCloud 下载（大视频是 GB 级）结束才生效。
    /// **归因契约**：只有能判定是网络造成的拉取失败（如 NSURLErrorDomain 的断网 / 超时）才返回 `.originalUnavailable`；
    /// 归因错了会让队头这张一直卡住后面的照片（它既不计次也不推进 G）。资源确实不可得要抛错。
    func importMedia(_ details: MediaDetails) async throws -> ImportResult

    /// 这份内容不再需要（桌面已有、放弃这一张、这一轮走不完）。幂等、不许抛。
    func release(_ contentHash: String)
}

// MARK: - 传输

/// 传一张的请求。queue_sequence = [orderId]，lease_token = [leaseTokenFor]。
public struct DeliveryRequest: Equatable, Sendable {
    public let orderId: Int64
    public let pairingEpoch: String
    public let contentHash: String
    public let details: MediaDetails

    public var leaseToken: String { leaseTokenFor(orderId) }
}

/// 一次传输的结局（#410 / #415 裁决 3 / #413 契约 §5）。
public enum DeliveryOutcome: Equatable, Sendable {
    case confirmed(CompletionReceipt)
    /// 原图没了 / 供数时内容变了：源已删，不计失败。
    case sourceMissing
    /// 这一张的问题：立即重试 1 次，仍失败记 FAILED、计次数。
    case itemFailure(String)
    /// 路走不通：order 保持「传输中」可续传，退出循环，不计次数。
    case pathFailure(String)
    /// 桌面自身的问题：退出循环，不计次数，原因带回手机显示。
    case peerFailure(PeerFailureKind, code: String)
    case pairingLost
}

/// 传输端口。
///
/// 取消（Task cancel：暂停 / 执行时间被收回 / 断网）时实现必须：停掉原生传输 → 同步、有界（约 3 秒）地发
/// `flow.suspend`（桌面保持 grant active、半截受保护）→ 再抛 `CancellationError`。**取消绝不发 `flow.cancel`**；
/// 丢弃半截只走显式的 [discardPartial]。
public protocol ItemDelivery: Sendable {
    /// 一轮传输的会话：持有执行租约期间整轮共用一条推送订阅，[body] 返回（或被取消）时关掉。
    func session<T>(_ body: () async throws -> T) async throws -> T

    func deliver(_ request: DeliveryRequest, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> DeliveryOutcome

    /// 通知桌面丢掉这一张已传的部分（`flow.cancel_tuple`）。有界等待，不许抛。
    func discardPartial(orderId: Int64, pairingEpoch: String) async
}

extension ItemDelivery {
    public func session<T>(_ body: () async throws -> T) async throws -> T { try await body() }
}

/// 桌面可达探测（`hello`，有超时）。
public enum ProbeResult: Equatable, Sendable {
    case reachable(advertisedEpoch: String?, health: DesktopHealth?, capabilities: Set<String>)
    case unreachable
    case pairingLost
}

/// 实现自己带超时；被取消时应尽快返回（引擎在返回后检查取消）。
public protocol DesktopProbe: Sendable {
    func probe() async -> ProbeResult
}

/// 对账：分页问桌面「这些 hash 你还在吗」，返回缺的那些。不可达时抛。
public protocol RemotePresence: Sendable {
    func missing(_ hashes: [String]) async throws -> Set<String>
}

// MARK: - 执行租约与唤醒

/// 执行租约 = 循环的生命周期（Android 的 FGS + wakelock 的 iOS 对位：前台，或 `beginBackgroundTask` 给的时间）。
/// [acquire] 每轮只调一次；拿不到返回 false，引擎进「等待中」，下一次触发照常再申请。
public protocol ExecutionLease: AnyObject, Sendable {
    func acquire() async -> Bool
    /// 租约仍有效（没被系统收回）。每张开始前检查。
    func isHeld() -> Bool
    /// 有进度就续期。
    func renew()
    func update(_ status: LoopStatus)
    func release()
    /// #958：当前只有短任务窗口开着（前台 / 宽限期 / 长任务都没开）。引擎据此不处理视频（20 秒内读不完，被打断要从头重来）。
    /// 每张开始前读取。默认 false（不改协议的线上格式，只是引擎本地的取件策略）。
    var photosOnly: Bool { get }
}

extension ExecutionLease {
    public var photosOnly: Bool { false }
}

/// 条件不满足时登记的唤醒。引擎只经 [wakePlanOf] 决定登记哪一种。
public protocol WakeScheduler: AnyObject, Sendable {
    /// 探测梯：4 个一次性唤醒，退避 10 / 20 / 40 / 80 分钟。iOS 上由 BGTaskScheduler 尽力兑现（#340）。
    func scheduleUnreachableProbes()
    func cancelUnreachableProbes()
    /// 条件不满足：一个带相应约束（Wi‑Fi / 电量）的一次性唤醒。
    func scheduleWhenConditionsMet(_ reason: WaitReason)
}

// MARK: - 视图

public struct CurrentItem: Equatable, Sendable {
    public let orderId: Int64
    public let fileName: String
    public var bytesSent: Int64
    public let totalBytes: Int64
}

public enum LoopPhase: Sendable { case idle, checking, running }

/// 循环的运行态（内存，不持久化）。
public struct LoopStatus: Equatable, Sendable {
    public var phase: LoopPhase = .idle
    public var current: CurrentItem?
    public var waitReason: WaitReason?

    public init(phase: LoopPhase = .idle, current: CurrentItem? = nil, waitReason: WaitReason? = nil) {
        self.phase = phase
        self.current = current
        self.waitReason = waitReason
    }
}

/// UI 与执行租约通知读的唯一视图。[pending] 是现算的待办张数。
public struct EngineView: Equatable, Sendable {
    public var state: GlobalState = .idle
    /// 仅 [GlobalState.waiting] 时非空。
    public var waitReason: WaitReason?
    public var pending: Int = 0
    public var doneThisRound: Int = 0
    public var current: CurrentItem?
    public var desktopHealth: DesktopHealth?
}

/// 「取消剩余 N 张」弹窗那一刻的边界：确认时只把这份边界里的照片写进跳过名单——弹窗之后新拍的不在里面。
public struct RemainingSnapshot: Sendable {
    public let count: Int
    public let takenAtMs: Int64
    let targets: [SkipTarget]
}

/// AUDIT-01：长期审计事件的种类（与 Android / daemon 同名）。
public enum AuditKinds {
    public static let roundFinished = "flow.round.finished"
    public static let roundControlled = "flow.round.controlled"
    public static let itemConfirmed = "flow.item.confirmed"
    public static let itemAttention = "flow.item.attention"
    public static let itemSourceMissing = "flow.item.source_missing"
    public static let reconciliationResolved = "flow.reconciliation.resolved"
}
