// 平台边界：控制面传输与内容哈希。PPassCore 不自己实现这两样——它们来自 #313 的 XCFramework
// （Rust `crates/transport` 的 iOS 绑定：BLAKE3、帧编解码、`call(method, params_json) -> resp_json`）。
// 这里只定义 protocol，核心与测试都对着 protocol 写；测试里用假实现。
import Foundation

/// 控制面一次往返。实现方（FFI）负责连接、鉴权、帧编解码与超时；
/// 输入是 `Req.params` 的 JSON，输出是完整 `Resp` 信封的 JSON。
public protocol CtrlTransport: Sendable {
    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data
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
        return try ProtoJSON.decode(Resp.self, from: data)
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
