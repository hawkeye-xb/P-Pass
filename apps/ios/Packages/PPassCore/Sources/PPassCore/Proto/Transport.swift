// 平台边界：控制面传输与内容哈希。PPassCore 不自己实现这两样——它们来自 #313 的 XCFramework
// （Rust `crates/transport` 的 iOS 绑定：BLAKE3、帧编解码、`call(method, params_json) -> resp_json`）。
// 这里只定义 protocol，核心与测试都对着 protocol 写；测试里用假实现。
import Foundation

/// 控制面一次往返。实现方（FFI）负责连接、鉴权、帧编解码与超时；
/// 输入是 `Req.params` 的 JSON，输出是完整 `Resp` 信封的 JSON。
public protocol CtrlTransport: Sendable {
    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data
}

/// 控制面流式调用（#963，`timeline.subscribe`）：发一次请求，之后对端推来的每一帧（JSON）都交给 [onFrame]，
/// 第一帧是应答本身。对端正常结束流时返回，连接出错时抛；[onFrame] 抛错 = 调用方不要这条流了，实现方要停流并把
/// 这个错误原样抛出。必须响应取消。
public protocol CtrlStreamTransport: Sendable {
    func stream(method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws
}

/// BLAKE3（hex，64 个小写十六进制字符）。来自 FFI，Swift 侧不实现第三份 BLAKE3。
public protocol ContentHasher: Sendable {
    func blake3Hex(of data: Data) throws -> String
    func blake3Hex(ofFileAt url: URL) throws -> String
}

/// 对端回了 `ok=false`：带着 code / msg_key 抛出，调用方按 code 分类。
public struct ProtoRejection: Error, Equatable, Sendable {
    public let method: String
    public let error: RespError?
}

/// 回包形状不对（`ok=true` 却没有 result、或 result 解不成期望类型）。
public struct ProtoMalformed: Error, Sendable {
    public let method: String
    public let detail: String
}

/// 类型化的控制面客户端：参数编码 → [CtrlTransport] → 解 `Resp` → 解 result。
public struct ProtoClient: Sendable {
    public let transport: CtrlTransport

    public init(transport: CtrlTransport) {
        self.transport = transport
    }

    /// 发一个请求，返回原始 `Resp`（调用方自己看 ok / error）。
    public func callRaw<P: Encodable>(_ method: String, _ params: P, timeoutMs: UInt64? = nil) async throws -> Resp {
        let data = try await transport.call(method: method, paramsJSON: ProtoJSON.encode(params), timeoutMs: timeoutMs)
        return try ProtoJSON.decode(Resp.self, from: data).versionChecked()
    }

    /// 发一个请求，`ok=false` 抛 [ProtoRejection]，否则把 result 解成 [R]。
    public func call<P: Encodable, R: Decodable>(_ method: String, _ params: P, as: R.Type, timeoutMs: UInt64? = nil) async throws -> R {
        let resp = try await callRaw(method, params, timeoutMs: timeoutMs)
        guard resp.ok else { throw ProtoRejection(method: method, error: resp.error) }
        guard let result = resp.result else { throw ProtoMalformed(method: method, detail: "ok without result") }
        do {
            return try result.decode(R.self)
        } catch {
            throw ProtoMalformed(method: method, detail: "\(error)")
        }
    }
}

// MARK: - #1072 / #1073 版本协商（手机这一半）

extension Resp {
    /// 对位 `proto::compatibility(LOCAL, peer, Role::Phone)`：对端版本低于本端最低接受版本 → 电脑太旧；
    /// 本端版本低于对端最低接受版本 → 手机太旧；nil = 兼容。v2 之前的电脑应答不带 `ver`（解码为 1），只有手机能判出来。
    static func outdatedSide(peerVer: UInt16, peerMinVer: UInt16) -> OutdatedSide? {
        if peerVer < ProtoVersion.minSupported { return .desktop }
        if ProtoVersion.current < peerMinVer { return .phone }
        return nil
    }

    /// 这条应答说哪一端太旧：先听电脑自己说的（`phone_outdated` / `desktop_outdated`），再自己核一次。
    public var outdatedSide: OutdatedSide? {
        if let error, case let .versionMismatch(side) = reasonClass(DesktopReason(error), channel: .reply),
           error.code == Codes.versionMismatch { return side }
        return Self.outdatedSide(peerVer: ver, peerMinVer: minVer)
    }

    /// 每条应答都过这里（[ProtoClient.callRaw]）：不兼容的电脑——不管它自己说了，还是旧到说不出来——对所有调用方
    /// 都是同一个样子：`VERSION_MISMATCH` + 那一端的 reason。兼容的应答原样返回。
    public func versionChecked() -> Resp {
        guard let side = outdatedSide else { return self }
        if !ok, error?.code == Codes.versionMismatch { return self }
        let reason: ProtoReason = side == .phone ? .phoneOutdated : .desktopOutdated
        var out = self
        out.ok = false
        out.result = nil
        out.error = RespError(code: Codes.versionMismatch, reason: reason.rawValue)
        return out
    }
}
