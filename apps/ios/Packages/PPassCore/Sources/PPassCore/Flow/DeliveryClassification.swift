// #891：传输端口的纯判定（对位 Android `NativeFlowDeliveryPort.kt` 文件里的顶层函数与 `IrohBlobsProviderBridge.parseTransferStatus`）。
// 全是纯函数：失败码分类（#410 / #413 契约 §5）、回执核对、推送匹配、等待循环下一步（C-10 / C-11）、状态轮询退避。
import Foundation

/// 桌面对一条请求回了 `ok=false`：对端**可达**、明确拒绝——不是路径问题。
public struct DesktopRejected: Error, Equatable, Sendable {
    public let msgKey: String?
    public let method: String
}

/// 配对已失效的拒绝文案（与 Android `isPairingLostText` 同一判据）。
public func isPairingLostText(_ text: String) -> Bool {
    text.contains("err.not_paired") || text.contains("err.not_authorized")
}

/// #413 契约 §5：桌面失败码的分类。
/// - `storage_full` / `library_unavailable` / `storage_failed` → 对端失败；
/// - `fetch_failed` → 路径失败；
/// - 其它（含旧桌面的 `materialize_*`）→ nil，由调用方当单张失败（计次数、有上限）。
public func classifyDesktopCode(_ code: String?) -> DeliveryOutcome? {
    switch code {
    case "storage_full": return .peerFailure(.storageFull, code: "storage_full")
    case "library_unavailable": return .peerFailure(.libraryUnavailable, code: "library_unavailable")
    case "storage_failed": return .peerFailure(.storageError, code: "storage_failed")
    case "fetch_failed": return .pathFailure("fetch_failed")
    default: return nil
    }
}

/// 推送的 `flow.failed`。
public func classifyPushedFailure(_ code: String) -> DeliveryOutcome {
    classifyDesktopCode(code) ?? .itemFailure("pushed:\(code)")
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
        if let key = rejected.msgKey, isPairingLostText(key) { return .pairingLost }
        return classifyDesktopCode(rejected.msgKey) ?? .itemFailure("rejected:\(rejected.msgKey ?? "nil")")
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
    case failed(String)
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
        if case let .string(code)? = fields["code"] { return .failed(code) }
        return .failed("unknown")
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
    case failed(String)
    /// C-10：连着、但很久没有新的文件字节——主动断开，路径失败。
    case stalled
    case keepWaitingForPush
    case checkStatusNow
}

/// - 推送优先：Delivered → 结账；Failed(code) → 按 code 分类。
/// - 本地终态（Completed / Aborted / NoLease）→ 问桌面要持久回执，绝不拿本地信号当回执。
/// - 进行中：字节停滞 ≥ [byteStallThresholdMs] → stalled（从最后一次字节前进算；还没字节就从这次尝试开始算）；
///   连着 → 安静等推送；没连着且空闲 ≥ [idleStallThresholdMs]（C-11：15 s）→ 问桌面。
public func flowWaitStep(pushed: FlowPushOutcome?, local: TransferStatus, idleStallThresholdMs: Int64, byteStallThresholdMs: Int64, attemptElapsedMs: Int64) -> FlowWaitStep {
    switch pushed {
    case let .delivered(receipt)?: return .resolved(.completed(receipt))
    case let .failed(code)?: return .failed(code)
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
