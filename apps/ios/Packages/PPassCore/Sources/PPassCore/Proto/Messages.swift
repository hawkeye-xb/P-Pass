// P-Pass 协议：crates/proto 线上 JSON 的 Swift 镜像（对位 Android `proto/Proto.kt`）。
//
// 逐字段对位 crates/proto/src/msgs.rs / error.rs / version.rs。漂移由 GoldenContractTests 抓：它解码的就是
// Rust 侧 `cargo test -p proto` 断言的那批 insta 样本（crates/proto/tests/snapshots），并要求重新编码后与样本
// **JSON 值全等**——比 Android 的子集比对更严，所以每个类型的编码都是手写的：
//   - `#[serde(default)]`           → 缺键取 Rust 的 Default（不是 Swift 的零值，例如 min_ver=1、limit=200、role="member"）
//   - `skip_serializing_if = …`      → 对应条件下省略键
//   - 不带 skip 的 `Option<T>`        → nil 写成显式 `null`（`encodeNullable`）
//
// 帧编解码（u32 LE 长度前缀）与 BLAKE3 不在这里：它们来自 #313 的 XCFramework，见 `Transport.swift`。
import Foundation

public enum ProtoVersion {
    public static let current: UInt16 = 1
    public static let minSupported: UInt16 = 1
}

// MARK: - Envelope

public struct Req: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var params: JSONValue
    public var minVer: UInt16

    public init(id: String = "", method: String = "", params: JSONValue = .null, minVer: UInt16 = ProtoVersion.minSupported) {
        self.id = id
        self.method = method
        self.params = params
        self.minVer = minVer
    }

    enum CodingKeys: String, CodingKey { case id, method, params, minVer = "min_ver" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: "")
        method = try c.value(.method, default: "")
        params = try c.value(.params, default: .null)
        minVer = try c.value(.minVer, default: ProtoVersion.minSupported)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(method, forKey: .method)
        try c.encode(params, forKey: .params)
        try c.encode(minVer, forKey: .minVer)
    }
}

/// 错误载荷。Rust 侧这个类型**没有** `#[serde(default)]`：两个字段缺一个就解码失败，这里同样严格。
public struct RespError: Codable, Equatable, Sendable, Error {
    public var code: String
    public var msgKey: String

    public init(code: String, msgKey: String) {
        self.code = code
        self.msgKey = msgKey
    }

    enum CodingKeys: String, CodingKey { case code, msgKey = "msg_key" }
}

public struct Resp: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: RespError?

    public init(id: String = "", ok: Bool = false, result: JSONValue? = nil, error: RespError? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case id, ok, result, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: "")
        ok = try c.value(.ok, default: false)
        // serde 把 `"result": null` 解成 None。
        result = try c.decodeIfPresent(JSONValue.self, forKey: .result).flatMap { $0 == .null ? nil : $0 }
        error = try c.decodeIfPresent(RespError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

// MARK: - Hello

public struct Hello: Codable, Equatable, Sendable {
    public var protoVer: UInt16
    public var capabilities: [String]
    public var deviceName: String
    /// 只有已配对成员会收到；未配对时省略。
    public var pairingEpoch: String?
    /// #413 §7：桌面健康。旧桌面不报 → nil，手机视为健康。
    public var health: DesktopHealthWire?

    public init(protoVer: UInt16 = ProtoVersion.current, capabilities: [String] = [], deviceName: String = "", pairingEpoch: String? = nil, health: DesktopHealthWire? = nil) {
        self.protoVer = protoVer
        self.capabilities = capabilities
        self.deviceName = deviceName
        self.pairingEpoch = pairingEpoch
        self.health = health
    }

    enum CodingKeys: String, CodingKey {
        case protoVer = "proto_ver", capabilities, deviceName = "device_name", pairingEpoch = "pairing_epoch", health
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protoVer = try c.value(.protoVer, default: ProtoVersion.current)
        capabilities = try c.value(.capabilities, default: [])
        deviceName = try c.value(.deviceName, default: "")
        pairingEpoch = try c.decodeIfPresent(String.self, forKey: .pairingEpoch)
        health = try c.decodeIfPresent(DesktopHealthWire.self, forKey: .health)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protoVer, forKey: .protoVer)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(pairingEpoch, forKey: .pairingEpoch)
        try c.encodeIfPresent(health, forKey: .health)
    }
}

/// `hello` 回复里的 `health`（Rust `DesktopHealth`）。字段名是固定的跨端契约。
///
/// **缺键默认值跟 Android，不跟 Rust**：Rust 的 derive Default 给两个布尔 `false`，Android 的 `HelloHealth`
/// 给 `true`。解释这个字段的是手机，两台手机必须对同一帧得出同一结论，所以跟 Android（登记在 PPassCore
/// 的差异清单里）。线上 daemon 总是三个键都写，这条分歧只在「缺键」时才显形。
public struct DesktopHealthWire: Codable, Equatable, Sendable {
    /// `null` = 这个平台答不上来，不是 0。
    public var freeBytes: Int64?
    public var libraryWritable: Bool
    public var indexOk: Bool

    public init(freeBytes: Int64? = nil, libraryWritable: Bool = true, indexOk: Bool = true) {
        self.freeBytes = freeBytes
        self.libraryWritable = libraryWritable
        self.indexOk = indexOk
    }

    enum CodingKeys: String, CodingKey { case freeBytes = "free_bytes", libraryWritable = "library_writable", indexOk = "index_ok" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        freeBytes = try c.decodeIfPresent(Int64.self, forKey: .freeBytes)
        libraryWritable = try c.value(.libraryWritable, default: true)
        indexOk = try c.value(.indexOk, default: true)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(freeBytes, forKey: .freeBytes)
        try c.encode(libraryWritable, forKey: .libraryWritable)
        try c.encode(indexOk, forKey: .indexOk)
    }
}

// MARK: - Pair

public struct PairRequest: Codable, Equatable, Sendable {
    public var token: String
    public var deviceName: String
    public var role: String
    /// NET-10：true = 排队即答、之后轮询 `pair.status`。false 时省略（旧帧逐字节不变）。
    public var ackThenPoll: Bool

    public init(token: String = "", deviceName: String = "", role: String = "member", ackThenPoll: Bool = false) {
        self.token = token
        self.deviceName = deviceName
        self.role = role
        self.ackThenPoll = ackThenPoll
    }

    enum CodingKeys: String, CodingKey { case token, deviceName = "device_name", role, ackThenPoll = "ack_then_poll" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.value(.token, default: "")
        deviceName = try c.value(.deviceName, default: "")
        role = try c.value(.role, default: "member")
        ackThenPoll = try c.value(.ackThenPoll, default: false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(role, forKey: .role)
        if ackThenPoll { try c.encode(true, forKey: .ackThenPoll) }
    }
}

public struct PairSubmitted: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var requestId: String
    public var ttlMs: Int64

    public init(accepted: Bool = false, requestId: String = "", ttlMs: Int64 = 0) {
        self.accepted = accepted
        self.requestId = requestId
        self.ttlMs = ttlMs
    }

    enum CodingKeys: String, CodingKey { case accepted, requestId = "request_id", ttlMs = "ttl_ms" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try c.value(.accepted, default: false)
        requestId = try c.value(.requestId, default: "")
        ttlMs = try c.value(.ttlMs, default: 0)
    }
}

public struct PairStatusRequest: Codable, Equatable, Sendable {
    public var requestId: String

    public init(requestId: String = "") { self.requestId = requestId }

    enum CodingKeys: String, CodingKey { case requestId = "request_id" }

    public init(from decoder: Decoder) throws {
        requestId = try decoder.container(keyedBy: CodingKeys.self).value(.requestId, default: "")
    }
}

public struct PairStatusReply: Codable, Equatable, Sendable {
    /// pending / accepted / denied / expired / not_found
    public var state: String
    public var accepted: PairAccepted?
    public var msgKey: String?

    public init(state: String = "", accepted: PairAccepted? = nil, msgKey: String? = nil) {
        self.state = state
        self.accepted = accepted
        self.msgKey = msgKey
    }

    enum CodingKeys: String, CodingKey { case state, accepted, msgKey = "msg_key" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.value(.state, default: "")
        accepted = try c.decodeIfPresent(PairAccepted.self, forKey: .accepted)
        msgKey = try c.decodeIfPresent(String.self, forKey: .msgKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(accepted, forKey: .accepted)
        try c.encodeIfPresent(msgKey, forKey: .msgKey)
    }
}

public struct PairAccepted: Codable, Equatable, Sendable {
    public var storageDeviceName: String
    public var pairingEpoch: String

    public init(storageDeviceName: String = "", pairingEpoch: String = "") {
        self.storageDeviceName = storageDeviceName
        self.pairingEpoch = pairingEpoch
    }

    enum CodingKeys: String, CodingKey { case storageDeviceName = "storage_device_name", pairingEpoch = "pairing_epoch" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storageDeviceName = try c.value(.storageDeviceName, default: "")
        pairingEpoch = try c.value(.pairingEpoch, default: "")
    }
}

// MARK: - Timeline

public struct TimelineQuery: Codable, Equatable, Sendable {
    /// 不带 skip：nil 写成 `null`。
    public var cursor: String?
    public var limit: UInt32

    public init(cursor: String? = nil, limit: UInt32 = 200) {
        self.cursor = cursor
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey { case cursor, limit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        limit = try c.value(.limit, default: 200)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(cursor, forKey: .cursor)
        try c.encode(limit, forKey: .limit)
    }
}

public struct TimelinePage: Codable, Equatable, Sendable {
    public var items: [AssetMeta]
    /// 不带 skip：nil 写成 `null`。
    public var next: String?

    public init(items: [AssetMeta] = [], next: String? = nil) {
        self.items = items
        self.next = next
    }

    enum CodingKeys: String, CodingKey { case items, next }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.value(.items, default: [])
        next = try c.decodeIfPresent(String.self, forKey: .next)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encodeNullable(next, forKey: .next)
    }
}

public struct AssetMeta: Codable, Equatable, Sendable {
    public var hash: String
    public var takenAt: Int64
    public var mediaType: String
    public var width: UInt32
    public var height: UInt32
    public var bytes: UInt64
    public var srcDevice: String?

    public init(hash: String = "", takenAt: Int64 = 0, mediaType: String = "", width: UInt32 = 0, height: UInt32 = 0, bytes: UInt64 = 0, srcDevice: String? = nil) {
        self.hash = hash
        self.takenAt = takenAt
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.bytes = bytes
        self.srcDevice = srcDevice
    }

    enum CodingKeys: String, CodingKey {
        case hash, takenAt = "taken_at", mediaType = "media_type", width, height, bytes, srcDevice = "src_device"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.value(.hash, default: "")
        takenAt = try c.value(.takenAt, default: 0)
        mediaType = try c.value(.mediaType, default: "")
        width = try c.value(.width, default: 0)
        height = try c.value(.height, default: 0)
        bytes = try c.value(.bytes, default: 0)
        srcDevice = try c.decodeIfPresent(String.self, forKey: .srcDevice)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hash, forKey: .hash)
        try c.encode(takenAt, forKey: .takenAt)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(bytes, forKey: .bytes)
        try c.encodeIfPresent(srcDevice, forKey: .srcDevice)
    }
}

// MARK: - Thumbnail

/// 线上是裸 u32（256 / 1024），不是字符串。其它值解码失败，与 Rust 一致。
public enum ThumbSize: UInt32, Codable, Equatable, Sendable {
    case s256 = 256
    case s1024 = 1024

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(UInt32.self)
        guard let size = ThumbSize(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown ThumbSize: \(raw) (expected 256 or 1024)"))
        }
        self = size
    }
}

public struct ThumbGet: Codable, Equatable, Sendable {
    public var hash: String
    public var size: ThumbSize

    public init(hash: String = "", size: ThumbSize = .s256) {
        self.hash = hash
        self.size = size
    }

    enum CodingKeys: String, CodingKey { case hash, size }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.value(.hash, default: "")
        size = try c.value(.size, default: .s256)
    }
}

public struct ThumbData: Codable, Equatable, Sendable {
    public var jpegBase64: String
    /// false 时省略。
    public var placeholder: Bool
    /// 0 时省略。
    public var retryAfterMs: UInt64

    public init(jpegBase64: String = "", placeholder: Bool = false, retryAfterMs: UInt64 = 0) {
        self.jpegBase64 = jpegBase64
        self.placeholder = placeholder
        self.retryAfterMs = retryAfterMs
    }

    enum CodingKeys: String, CodingKey { case jpegBase64 = "jpeg_base64", placeholder, retryAfterMs = "retry_after_ms" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jpegBase64 = try c.value(.jpegBase64, default: "")
        placeholder = try c.value(.placeholder, default: false)
        retryAfterMs = try c.value(.retryAfterMs, default: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jpegBase64, forKey: .jpegBase64)
        if placeholder { try c.encode(true, forKey: .placeholder) }
        if retryAfterMs != 0 { try c.encode(retryAfterMs, forKey: .retryAfterMs) }
    }
}

// MARK: - Blob ticket

public struct BlobTicketRequest: Codable, Equatable, Sendable {
    public var hash: String

    public init(hash: String = "") { self.hash = hash }

    public init(from decoder: Decoder) throws {
        hash = try decoder.container(keyedBy: CodingKeys.self).value(.hash, default: "")
    }
}

public struct BlobTicketResponse: Codable, Equatable, Sendable {
    public var ticket: String

    public init(ticket: String = "") { self.ticket = ticket }

    public init(from decoder: Decoder) throws {
        ticket = try decoder.container(keyedBy: CodingKeys.self).value(.ticket, default: "")
    }
}

// MARK: - Flow 逐张交付

/// `flow.offer` / `flow.fetch` / `flow.cancel` 的参数。queue_sequence = order 行 id，lease_token = `lease-<id>`。
public struct FlowFetchRequest: Codable, Equatable, Sendable {
    public var queueSequence: UInt64
    public var pairingEpoch: String
    public var leaseToken: String
    public var contentHash: String
    public var fileName: String
    public var mediaType: String
    /// 这份内容的 iroh-blobs ticket。
    public var provider: String
    /// 拍摄时刻（unix ms；0 = 不知道）。
    public var captureAtMs: Int64
    /// 字节数（0 = 不知道）；桌面 offer 时按它预检空间。
    public var sizeBytes: Int64

    public init(queueSequence: UInt64 = 0, pairingEpoch: String = "", leaseToken: String = "", contentHash: String = "", fileName: String = "", mediaType: String = "", provider: String = "", captureAtMs: Int64 = 0, sizeBytes: Int64 = 0) {
        self.queueSequence = queueSequence
        self.pairingEpoch = pairingEpoch
        self.leaseToken = leaseToken
        self.contentHash = contentHash
        self.fileName = fileName
        self.mediaType = mediaType
        self.provider = provider
        self.captureAtMs = captureAtMs
        self.sizeBytes = sizeBytes
    }

    enum CodingKeys: String, CodingKey {
        case queueSequence = "queue_sequence", pairingEpoch = "pairing_epoch", leaseToken = "lease_token"
        case contentHash = "content_hash", fileName = "file_name", mediaType = "media_type", provider
        case captureAtMs = "capture_at_ms", sizeBytes = "size_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queueSequence = try c.value(.queueSequence, default: 0)
        pairingEpoch = try c.value(.pairingEpoch, default: "")
        leaseToken = try c.value(.leaseToken, default: "")
        contentHash = try c.value(.contentHash, default: "")
        fileName = try c.value(.fileName, default: "")
        mediaType = try c.value(.mediaType, default: "")
        provider = try c.value(.provider, default: "")
        captureAtMs = try c.value(.captureAtMs, default: 0)
        sizeBytes = try c.value(.sizeBytes, default: 0)
    }
}

/// #851：用原图原地替换桌面上抹过地点的旧副本。iOS 不发它（见变体登记），只做线上镜像。
public struct FlowSupersedeRequest: Codable, Equatable, Sendable {
    public var pairingEpoch: String
    public var oldHash: String
    public var newHash: String
    public var provider: String

    public init(pairingEpoch: String = "", oldHash: String = "", newHash: String = "", provider: String = "") {
        self.pairingEpoch = pairingEpoch
        self.oldHash = oldHash
        self.newHash = newHash
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey { case pairingEpoch = "pairing_epoch", oldHash = "old_hash", newHash = "new_hash", provider }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairingEpoch = try c.value(.pairingEpoch, default: "")
        oldHash = try c.value(.oldHash, default: "")
        newHash = try c.value(.newHash, default: "")
        provider = try c.value(.provider, default: "")
    }
}

public struct FlowSupersedeReply: Codable, Equatable, Sendable {
    /// replaced / refused
    public var outcome: String
    /// 空串时省略。
    public var reason: String

    public init(outcome: String = "", reason: String = "") {
        self.outcome = outcome
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case outcome, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.value(.outcome, default: "")
        reason = try c.value(.reason, default: "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcome, forKey: .outcome)
        if !reason.isEmpty { try c.encode(reason, forKey: .reason) }
    }
}

/// 桌面给出的完成凭据：只在内容可靠落盘之后才有。
public struct FlowCompletionReceipt: Codable, Equatable, Sendable {
    public var queueSequence: UInt64
    public var receiptId: String
    public var pairingEpoch: String
    public var leaseToken: String
    public var contentHash: String

    public init(queueSequence: UInt64 = 0, receiptId: String = "", pairingEpoch: String = "", leaseToken: String = "", contentHash: String = "") {
        self.queueSequence = queueSequence
        self.receiptId = receiptId
        self.pairingEpoch = pairingEpoch
        self.leaseToken = leaseToken
        self.contentHash = contentHash
    }

    enum CodingKeys: String, CodingKey {
        case queueSequence = "queue_sequence", receiptId = "receipt_id", pairingEpoch = "pairing_epoch"
        case leaseToken = "lease_token", contentHash = "content_hash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queueSequence = try c.value(.queueSequence, default: 0)
        receiptId = try c.value(.receiptId, default: "")
        pairingEpoch = try c.value(.pairingEpoch, default: "")
        leaseToken = try c.value(.leaseToken, default: "")
        contentHash = try c.value(.contentHash, default: "")
    }
}

/// `flow.status` / `flow.suspend` / `flow.cancel_tuple` 的参数：只按 tuple 身份定位，不带 hash / provider。
public struct FlowTupleRef: Codable, Equatable, Sendable {
    public var queueSequence: UInt64
    public var pairingEpoch: String
    public var leaseToken: String

    public init(queueSequence: UInt64 = 0, pairingEpoch: String = "", leaseToken: String = "") {
        self.queueSequence = queueSequence
        self.pairingEpoch = pairingEpoch
        self.leaseToken = leaseToken
    }

    enum CodingKeys: String, CodingKey { case queueSequence = "queue_sequence", pairingEpoch = "pairing_epoch", leaseToken = "lease_token" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queueSequence = try c.value(.queueSequence, default: 0)
        pairingEpoch = try c.value(.pairingEpoch, default: "")
        leaseToken = try c.value(.leaseToken, default: "")
    }
}

public struct FlowStatusReply: Codable, Equatable, Sendable {
    /// active / completed / cancelled / not_found
    public var state: String
    public var receipt: FlowCompletionReceipt?
    public var taskRunning: Bool

    public init(state: String = "", receipt: FlowCompletionReceipt? = nil, taskRunning: Bool = false) {
        self.state = state
        self.receipt = receipt
        self.taskRunning = taskRunning
    }

    enum CodingKeys: String, CodingKey { case state, receipt, taskRunning = "task_running" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.value(.state, default: "")
        receipt = try c.decodeIfPresent(FlowCompletionReceipt.self, forKey: .receipt)
        taskRunning = try c.value(.taskRunning, default: false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(receipt, forKey: .receipt)
        try c.encode(taskRunning, forKey: .taskRunning)
    }
}

// MARK: - Flow 审计 outbox（AUDIT-01）

public struct FlowAuditEvent: Codable, Equatable, Sendable {
    public var eventId: String
    public var kind: String
    public var roundId: String?
    public var occurredAtMs: Int64
    public var payload: [String: String]

    public init(eventId: String = "", kind: String = "", roundId: String? = nil, occurredAtMs: Int64 = 0, payload: [String: String] = [:]) {
        self.eventId = eventId
        self.kind = kind
        self.roundId = roundId
        self.occurredAtMs = occurredAtMs
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey { case eventId = "event_id", kind, roundId = "round_id", occurredAtMs = "occurred_at_ms", payload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.value(.eventId, default: "")
        kind = try c.value(.kind, default: "")
        roundId = try c.decodeIfPresent(String.self, forKey: .roundId)
        occurredAtMs = try c.value(.occurredAtMs, default: 0)
        payload = try c.value(.payload, default: [:])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventId, forKey: .eventId)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(roundId, forKey: .roundId)
        try c.encode(occurredAtMs, forKey: .occurredAtMs)
        try c.encode(payload, forKey: .payload)
    }
}

public struct FlowAuditSubmit: Codable, Equatable, Sendable {
    public var events: [FlowAuditEvent]

    public init(events: [FlowAuditEvent] = []) { self.events = events }

    public init(from decoder: Decoder) throws {
        events = try decoder.container(keyedBy: CodingKeys.self).value(.events, default: [])
    }
}

public struct FlowAuditAccepted: Codable, Equatable, Sendable {
    public var eventIds: [String]

    public init(eventIds: [String] = []) { self.eventIds = eventIds }

    enum CodingKeys: String, CodingKey { case eventIds = "event_ids" }

    public init(from decoder: Decoder) throws {
        eventIds = try decoder.container(keyedBy: CodingKeys.self).value(.eventIds, default: [])
    }
}

// MARK: - Backup（冻结的批量协议；Flow 只用 presence 做对账）

public struct BackupBegin: Codable, Equatable, Sendable {
    public init() {}
}

public struct BackupItem: Codable, Equatable, Sendable {
    public var hash: String
    public var fileName: String
    public var mediaType: String

    public init(hash: String = "", fileName: String = "", mediaType: String = "") {
        self.hash = hash
        self.fileName = fileName
        self.mediaType = mediaType
    }

    enum CodingKeys: String, CodingKey { case hash, fileName = "file_name", mediaType = "media_type" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.value(.hash, default: "")
        fileName = try c.value(.fileName, default: "")
        mediaType = try c.value(.mediaType, default: "")
    }
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public var hashes: [String]
    /// 空时省略。
    public var items: [BackupItem]
    public var provider: String?

    public init(hashes: [String] = [], items: [BackupItem] = [], provider: String? = nil) {
        self.hashes = hashes
        self.items = items
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey { case hashes, items, provider }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hashes = try c.value(.hashes, default: [])
        items = try c.value(.items, default: [])
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hashes, forKey: .hashes)
        if !items.isEmpty { try c.encode(items, forKey: .items) }
        try c.encodeIfPresent(provider, forKey: .provider)
    }
}

/// 对账：分页问桌面「这些 hash 你还在吗」（`backup.presence`）。
public struct BackupPresenceQuery: Codable, Equatable, Sendable {
    public var hashes: [String]

    public init(hashes: [String] = []) { self.hashes = hashes }

    public init(from decoder: Decoder) throws {
        hashes = try decoder.container(keyedBy: CodingKeys.self).value(.hashes, default: [])
    }
}

public struct BackupMissing: Codable, Equatable, Sendable {
    public var hashes: [String]

    public init(hashes: [String] = []) { self.hashes = hashes }

    public init(from decoder: Decoder) throws {
        hashes = try decoder.container(keyedBy: CodingKeys.self).value(.hashes, default: [])
    }
}

public struct BackupCommit: Codable, Equatable, Sendable {
    public var generation: Int64?

    public init(generation: Int64? = nil) { self.generation = generation }

    public init(from decoder: Decoder) throws {
        generation = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Int64.self, forKey: .generation)
    }
}

public struct UploadHeader: Codable, Equatable, Sendable {
    public var hash: String
    public var bytes: UInt64
    public var fileName: String

    public init(hash: String = "", bytes: UInt64 = 0, fileName: String = "") {
        self.hash = hash
        self.bytes = bytes
        self.fileName = fileName
    }

    enum CodingKeys: String, CodingKey { case hash, bytes, fileName = "file_name" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.value(.hash, default: "")
        bytes = try c.value(.bytes, default: 0)
        fileName = try c.value(.fileName, default: "")
    }
}

// MARK: - Diagnostics

public struct DiagStatusQuery: Codable, Equatable, Sendable {
    public init() {}
}

public struct DiagStatus: Codable, Equatable, Sendable {
    public var state: String
    /// 不带 skip：nil 写成 `null`。
    public var detail: String?

    public init(state: String = "", detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case state, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.value(.state, default: "")
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(detail, forKey: .detail)
    }
}

// MARK: - 常量

public enum Methods {
    public static let hello = "hello"
    public static let pairRequest = "pair.request"
    public static let pairStatus = "pair.status"
    public static let pairCancel = "pair.cancel"
    public static let timelinePage = "timeline.page"
    public static let assetMeta = "asset.meta"
    public static let thumbGet = "thumb.get"
    public static let assetBlobTicket = "asset.blob_ticket"
    public static let flowOffer = "flow.offer"
    public static let flowFetch = "flow.fetch"
    public static let flowCancel = "flow.cancel"
    public static let flowStatus = "flow.status"
    public static let flowSuspend = "flow.suspend"
    public static let flowCancelTuple = "flow.cancel_tuple"
    public static let flowAuditSubmit = "flow.audit.submit"
    public static let flowSupersede = "flow.supersede"
    public static let backupBegin = "backup.begin"
    public static let backupManifest = "backup.manifest"
    public static let backupPresence = "backup.presence"
    public static let backupCommit = "backup.commit"
    public static let diagStatus = "diag.status"
    public static let backupUpload = "backup.upload"
    public static let assetDownload = "asset.download"
    public static let deviceUnpair = "device.unpair"
    public static let timelineSubscribe = "timeline.subscribe"
}

public enum Capabilities {
    /// #851：桌面支持 `flow.supersede`。
    public static let flowSupersede = "flow.supersede.v1"
}

public enum Codes {
    public static let notAuthorized = "NOT_AUTHORIZED"
    public static let invalidRequest = "INVALID_REQUEST"
    public static let notFound = "NOT_FOUND"
    public static let storageFull = "STORAGE_FULL"
    public static let versionMismatch = "VERSION_MISMATCH"
    public static let `internal` = "INTERNAL"
}
