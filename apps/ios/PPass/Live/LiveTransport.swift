import Foundation
import PPassCore
import PPassTransport
import Security

/// 这台手机的 iroh 身份（32 字节）。配对绑的是 NodeId，所以必须持久化（对位 Android `IdentityStore`）。
/// 存在存储根目录的 `identity.key`——断开清单里它是 keep：断开后再配对还是同一台手机。
enum IdentityKey {
    static func loadOrCreate(in root: URL) throws -> Data {
        let url = root.appendingPathComponent("identity.key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = Data(bytes)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return data
    }
}

/// 控制面客户端（FFI `CtrlClient`）：一个进程一个，懒绑定。FFI 调用是同步阻塞的，一律放到后台线程。
final class ControlPlane: @unchecked Sendable {
    private let secretKey: Data
    private let lock = NSLock()
    private var client: CtrlClient?

    init(secretKey: Data) { self.secretKey = secretKey }

    func bound() throws -> CtrlClient {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }
        let c = try CtrlClient.bind(config: CtrlConfig(secretKey: secretKey, relayUrls: [], offline: false, bindTimeoutMs: 0))
        client = c
        return c
    }

    func nodeId() throws -> String { try bound().nodeId() }

    /// 一次请求一帧回复；返回完整 Resp 信封 JSON。
    func call(peerToken: String, method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        let params = String(decoding: paramsJSON, as: UTF8.self)
        return try await Task.detached(priority: .userInitiated) { [self] in
            let reply = try bound().call(peerToken: peerToken, method: method, paramsJson: params, timeoutMs: timeoutMs ?? 0)
            return Data(reply.utf8)
        }.value
    }
}

/// PPassCore 的 `CtrlTransport` 端口：对端固定为配对时存下的 peer token。
struct PeerCtrlTransport: CtrlTransport {
    let plane: ControlPlane
    let peerToken: String

    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        try await plane.call(peerToken: peerToken, method: method, paramsJSON: paramsJSON, timeoutMs: timeoutMs)
    }
}

/// BLAKE3 一律走 FFI（规划：iOS 不第三次实现 BLAKE3）。
struct FfiHasher: ContentHasher {
    func blake3Hex(of data: Data) throws -> String { PPassTransport.blake3Hex(data: data) }
    func blake3Hex(ofFileAt url: URL) throws -> String { try blake3FileHex(path: url.path) }
}
