// #891：传输端口的纯判定（对位 Android `NativeFlowDeliveryPort.kt` 文件里的顶层函数与 `IrohBlobsProviderBridge.parseTransferStatus`）。
// 全是纯函数：失败码分类（#410 / #413 契约 §5）、回执核对、推送匹配、等待循环下一步（C-10 / C-11）、状态轮询退避。
import Foundation

/// #1073：桌面错误应答里的 `reason`（协议 v2 登记表，见 `ProtoReason`）。登记表外的值原样保留在 `.unknown` 里，
/// 只用于日志——控制流与文案都只认登记过的值，不认识的一律走兜底。
public enum DesktopReason: Equatable, Sendable, CustomStringConvertible {
    case registered(ProtoReason)
    case unknown(String)

    public init(wire: String) {
        let known = ProtoReason(wire: wire)
        self = known == .unknown ? .unknown(wire) : .registered(known)
    }

    public init(_ error: RespError?) { self.init(wire: error?.reason ?? "") }

    public var description: String {
        switch self {
        case let .registered(r): return r.rawValue
        case let .unknown(raw): return raw.isEmpty ? "unknown" : "unknown:\(raw)"
        }
    }
}

/// 版本不兼容时太旧的是哪一端（#1069 §2）。
public enum OutdatedSide: String, Equatable, Sendable {
    case phone
    case desktop
}

/// 一条 `reason` 的控制流归类（#1069 拍板：按「问题出在哪、谁能解决」，#1072 / #1073 两端逐条一致）。
public enum ReasonClass: Equatable, Sendable {
    /// 配对已失效：红卡、停备份，出路是重新扫码。
    case pairingLost
    /// 协议版本不兼容：停备份、不计失败、不动配对，提示更新 [OutdatedSide] 那一端。
    case versionMismatch(OutdatedSide)
    /// 电脑端的问题：退出本轮，不计次数，原因带回手机显示。
    case peerFailure(PeerFailureKind)
    /// 网络：路走不通，可续传，不计次数。
    case pathFailure
    /// 不该发生的错误（手机发错请求 / 两端记录对不上 / 不认识的 reason）：走现有的单张失败——跳过这一张、计次数、
    /// 继续后面的照片，由对账轮重试，日志记下 reason（#1069 / #1072 最终拍板）。
    case itemFailure
}

/// #1073 归类表（与 Android `ReasonPolicy.kt` 同一张，应答与 `flow.failed` 推送共用）。
/// `ProtoReason` 的 switch 不带 `default`：登记表新增一个值，这里编译不过，逼着显式归类。
public func reasonClass(_ reason: DesktopReason) -> ReasonClass {
    guard case let .registered(r) = reason else { return .itemFailure }
    switch r {
    case .notPaired, .revoked, .epochMismatch, .roleForbidden: return .pairingLost
    case .phoneOutdated: return .versionMismatch(.phone)
    // 电脑不认识手机调用的方法：电脑那边的 P-Pass 太旧。
    case .desktopOutdated, .unsupportedMethod: return .versionMismatch(.desktop)
    case .storageFull: return .peerFailure(.storageFull)
    case .libraryUnavailable: return .peerFailure(.libraryUnavailable)
    case .storageFailed: return .peerFailure(.storageError)
    case .internal: return .peerFailure(.desktopInternal)
    case .fetchFailed: return .pathFailure
    case .badRequest, .notFound, .backupFailed, .cancelled, .pairTokenInvalid, .grantNotFound, .grantConflict, .unknown:
        return .itemFailure
    }
}

/// 桌面对一条请求回了 `ok=false`：对端**可达**、明确拒绝——不是路径问题。
public struct DesktopRejected: Error, Equatable, Sendable {
    public let reason: DesktopReason
    public let method: String

    public init(reason: DesktopReason, method: String) {
        self.reason = reason
        self.method = method
    }

    public init(_ error: RespError?, method: String) { self.init(reason: DesktopReason(error), method: method) }

    public var reasonClass: ReasonClass { PPassCore.reasonClass(reason) }
    public var isPairingLost: Bool { reasonClass == .pairingLost }
}

/// 归类 → 传输结局；单张失败由调用方带上自己的说明（`rejected:` / `pushed:` 前缀，日志里看得出来源）。
func deliveryOutcome(_ reason: DesktopReason, _ cls: ReasonClass) -> DeliveryOutcome? {
    switch cls {
    case .pairingLost: return .pairingLost
    case let .versionMismatch(side): return .versionMismatch(side)
    case let .peerFailure(kind): return .peerFailure(kind, code: reason.description)
    case .pathFailure: return .pathFailure(reason.description)
    case .itemFailure: return nil
    }
}

/// 推送的 `flow.failed`。
public func classifyPushedFailure(_ reason: DesktopReason) -> DeliveryOutcome {
    deliveryOutcome(reason, reasonClass(reason)) ?? .itemFailure("pushed:\(reason)")
}

/// 回执与请求不符（四个字段任何一个对不上）：不许确认这张 order。
public struct ReceiptMismatch: Error, Equatable, Sendable {
    public let field: String
}

/// 回包不自洽（`completed` 却没有回执、桌面说找不到我们自己的 grant 等）。
public struct InconsistentReply: Error, Equatable, Sendable {
    public let detail: String
}

/// 传输过程中抛出的错误的分类。桌面可达且明确拒绝不是路径问题（否则一条坏请求每次都把循环停下、且永不计次）。
public func classifyDeliveryFailure(_ error: Error) -> DeliveryOutcome {
    if let rejected = error as? DesktopRejected {
        return deliveryOutcome(rejected.reason, rejected.reasonClass) ?? .itemFailure("rejected:\(rejected.reason)")
    }
    if error is ReceiptMismatch || error is InconsistentReply || error is DecodingError || error is ProtoMalformed {
        return .itemFailure("invalid:\(type(of: error))")
    }
    return .pathFailure("network:\(type(of: error))")
}

/// 原生 provider 供数失败。
public enum ProviderFailure: Error, Equatable, Sendable {
    /// 原图没了（引用导入的文件被删）。
    case sourceMissing
    /// 导入之后原文件被改 / 截断：内容与导入时的 hash 对不上。
    case sourceChanged
    /// provider 端点在限时内没上线（`wait_online` 超时）——网络问题，不是这张照片的问题。
    case offline(String)
}

/// 供数失败的分类：源已删 / 已变 → 源已删（不计失败）；provider 上线超时 → 路径失败；其它 → 单张失败。
public func classifyProviderFailure(_ error: Error) -> DeliveryOutcome {
    switch error as? ProviderFailure {
    case .sourceMissing?, .sourceChanged?: return .sourceMissing
    case .offline?: return .pathFailure("provider_offline")
    case nil:
        let text = "\(error)"
        if text.contains("does not match its declared content hash") { return .sourceMissing }
        if text.contains("did not become online") { return .pathFailure("provider_offline") }
        return .itemFailure("provider:\(type(of: error))")
    }
}

/// 回执四字段核对通过之前，不许确认 order（REBUILD-03）。
public func relayFlowCompletion(_ receipt: FlowCompletionReceipt, _ request: FlowFetchRequest) throws -> CompletionReceipt {
    guard receipt.queueSequence == request.queueSequence else { throw ReceiptMismatch(field: "queue_sequence") }
    guard receipt.pairingEpoch == request.pairingEpoch else { throw ReceiptMismatch(field: "pairing_epoch") }
    guard receipt.leaseToken == request.leaseToken else { throw ReceiptMismatch(field: "lease_token") }
    guard receipt.contentHash == request.contentHash else { throw ReceiptMismatch(field: "content_hash") }
    return CompletionReceipt(
        queueSequence: Int64(receipt.queueSequence), receiptId: receipt.receiptId, pairingEpoch: receipt.pairingEpoch,
        contentHash: receipt.contentHash, leaseToken: receipt.leaseToken
    )
}

/// NET-06：对一次 `FlowStatusReply` 的判定。`not_found` 是真正的不一致（桌面没有我们自己的 grant）。
public enum FlowStatusPollOutcome: Equatable, Sendable {
    case completed(FlowCompletionReceipt)
    case cancelled
    case keepPolling
}

public func flowStatusPollOutcome(_ reply: FlowStatusReply) throws -> FlowStatusPollOutcome {
    switch reply.state {
    case "completed":
        guard let receipt = reply.receipt else { throw InconsistentReply(detail: "flow.status: completed with no receipt") }
        return .completed(receipt)
    case "cancelled": return .cancelled
    case "not_found": throw InconsistentReply(detail: "flow.status: daemon has no record of our own grant")
    default: return .keepPolling
    }
}

/// NET-14：与这次尝试的 tuple 精确匹配的 `flow.delivered` / `flow.failed` 推送。
public enum FlowPushOutcome: Equatable, Sendable {
    case delivered(FlowCompletionReceipt)
    case failed(DesktopReason)
}

public func parseFlowPushOutcome(kind: String, data: JSONValue, tuple: FlowTupleRef) -> FlowPushOutcome? {
    guard case let .object(fields) = data else { return nil }
    let seq: UInt64?
    switch fields["queue_sequence"] {
    case let .int(v)?: seq = v >= 0 ? UInt64(v) : nil
    case let .uint(v)?: seq = v
    case let .string(s)?: seq = UInt64(s)
    default: seq = nil
    }
    guard let seq, case let .string(epoch)? = fields["pairing_epoch"], case let .string(lease)? = fields["lease_token"] else { return nil }
    guard seq == tuple.queueSequence, epoch == tuple.pairingEpoch, lease == tuple.leaseToken else { return nil }
    switch kind {
    case "flow.delivered":
        guard let element = fields["receipt"], let receipt = try? element.decode(FlowCompletionReceipt.self) else { return nil }
        return .delivered(receipt)
    case "flow.failed":
        // #1070：载荷的 `code` 改名为 `reason`。
        if case let .string(reason)? = fields["reason"] { return .failed(DesktopReason(wire: reason)) }
        return .failed(.unknown(""))
    default:
        return nil
    }
}

/// 引用导入的原图在供数期间出了问题（每次查询状态时现场 stat 得出）。
public enum SourceFault: String, Sendable {
    case missing
    case changed
}

/// 原生 provider 作为 iroh-blobs 发送端能观察到的本地传输状态（对位 Android `TransferStatus`）。
public enum TransferStatus: Equatable, Sendable {
    case noLease
    case completed(hash: String)
    case aborted(hash: String, source: SourceFault?)
    /// [bytesSent] / [byteIdleForMs]：对端已拉走的文件字节数与它上一次前进至今多久；旧版原生库不带 → nil。
    case inProgress(connected: Bool, idleForMs: Int64?, bytesSent: Int64?, byteIdleForMs: Int64?, source: SourceFault?)

    /// 原生库给出的 JSON（与 Android 同一形状）。不认识的 state 降级为 noLease：这是本地便利信号，不是持久契约。
    public static func parse(_ json: Data) -> TransferStatus {
        guard case let .object(f)? = try? JSONValue.parse(json) else { return .noLease }
        func str(_ k: String) -> String? { if case let .string(s)? = f[k] { return s }; return nil }
        func int(_ k: String) -> Int64? {
            switch f[k] {
            case let .int(v)?: return v
            case let .uint(v)?: return Int64(clamping: v)
            default: return nil
            }
        }
        let source = str("source").flatMap(SourceFault.init(rawValue:))
        switch str("state") {
        case "completed": return str("hash").map { .completed(hash: $0) } ?? .noLease
        case "aborted": return str("hash").map { .aborted(hash: $0, source: source) } ?? .noLease
        case "in_progress":
            var connected = false
            if case let .bool(b)? = f["connected"] { connected = b }
            return .inProgress(connected: connected, idleForMs: int("idle_for_ms"), bytesSent: int("bytes_sent"), byteIdleForMs: int("byte_idle_for_ms"), source: source)
        default: return .noLease
        }
    }
}

/// NET-14 / #410：等待循环的下一步。
public enum FlowWaitStep: Equatable, Sendable {
    case resolved(FlowStatusPollOutcome)
    case failed(DesktopReason)
    /// C-10：连着、但很久没有新的文件字节——主动断开，路径失败。
    case stalled
    case keepWaitingForPush
    case checkStatusNow
}

/// - 推送优先：Delivered → 结账；Failed(reason) → 按 reason 分类。
/// - 本地终态（Completed / Aborted / NoLease）→ 问桌面要持久回执，绝不拿本地信号当回执。
/// - 进行中：字节停滞 ≥ [byteStallThresholdMs] → stalled（从最后一次字节前进算；还没字节就从这次尝试开始算）；
///   连着 → 安静等推送；没连着且空闲 ≥ [idleStallThresholdMs]（C-11：15 s）→ 问桌面。
public func flowWaitStep(pushed: FlowPushOutcome?, local: TransferStatus, idleStallThresholdMs: Int64, byteStallThresholdMs: Int64, attemptElapsedMs: Int64) -> FlowWaitStep {
    switch pushed {
    case let .delivered(receipt)?: return .resolved(.completed(receipt))
    case let .failed(reason)?: return .failed(reason)
    case nil: break
    }
    switch local {
    case .completed, .aborted, .noLease:
        return .checkStatusNow
    case let .inProgress(connected, idleForMs, _, byteIdleForMs, _):
        let sinceBytes = byteIdleForMs ?? attemptElapsedMs
        if sinceBytes >= byteStallThresholdMs { return .stalled }
        if connected { return .keepWaitingForPush }
        if (idleForMs ?? attemptElapsedMs) >= idleStallThresholdMs { return .checkStatusNow }
        return .keepWaitingForPush
    }
}

/// NET-06：状态轮询退避——起步快、封顶，不无限增长。
public func nextStatusPollDelayMs(_ index: Int) -> Int64 {
    let delays: [Int64] = [1_000, 2_000, 3_000, 5_000, 8_000]
    return delays[min(max(index, 0), delays.count - 1)]
}

/// 传输端口的时间参数（与 Android 同值；测试里可以整体缩小）。
public struct DeliveryTimings: Sendable {
    /// C-11：没人来连多久就去问桌面。
    public var idleStallThresholdMs: Int64 = 15_000
    /// C-10：连接还在但多久没有新的文件字节就判路径失败。
    public var byteStallThresholdMs: Int64 = 180_000
    /// 推送订阅断开后的重建退避（封顶 10 s）。
    public var subscriptionRetryDelaysMs: [Int64] = [1_000, 2_000, 5_000, 10_000]
    /// 等待循环多久重读一次本地信号。
    public var localStatusRecheckMs: Int64 = 500
    /// 每轮首张 offer 之前最多等订阅就绪多久（超时照样 offer，status 兜底）。
    public var subscriptionReadyTimeoutMs: Int64 = 2_000
    /// 本地中止 / 推送订阅丢了之后那一次 `flow.status` 最多等多久。
    public var stallStatusTimeoutMs: Int64 = 3_000
    /// `flow.suspend` / `flow.cancel_tuple` 最多等多久（暂停不能被一次 15 秒的连接超时卡住）。
    public var controlCallTimeoutMs: Int64 = 3_000
    /// 连着这么多次状态往返失败就放弃这次尝试（路径失败）。
    public var statusPollMaxConsecutiveFailures = 5
    /// 状态轮询退避（测试里可以缩小）。
    public var statusPollDelayScale: Double = 1

    public init() {}
}
