import Foundation
import PPassCore
import PPassTransport
import Security

/// 这台手机的 iroh 身份私钥（32 字节）在钥匙串里的那一项（判定逻辑在 PPassCore `DeviceIdentity`）。
/// 首次解锁后可读（后台任务常在锁屏时跑）、仅本设备（不进备份、不随换机迁移）、不随 iCloud 钥匙串同步。
/// 用 App 的默认访问组：只有主 App 一个进程读它；将来加扩展要共享，再迁到共享组。
struct KeychainIdentityStore: IdentitySecretStore {
    var service = "com.hawkeyexb.ppass.identity"
    var account = "device-ed25519"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw Self.error("read", status)
        }
    }

    func write(_ key: Data) throws {
        var item = base
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error("write", status) }
    }

    func delete() throws {
        var query = base
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error("delete", status) }
    }

    private static func error(_ op: String, _ status: OSStatus) -> IdentityStoreError {
        status == errSecInteractionNotAllowed ? .locked : .failed(op: op, status: status)
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

    /// 按票据把一个 blob 拉到 [dest]（控制端点出站连 blobs；临时仓库用完即删），返回内容 BLAKE3 hex。
    /// FFI 同步阻塞，放后台线程；任务被取消时触发 FetchCancel 中止取回，并抛 CancellationError。
    func fetchBlob(ticket: String, scratch: URL, dest: URL, progress: @escaping @Sendable (UInt64) -> Void) async throws -> String {
        let cancel = FetchCancel()
        do {
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) { [self] in
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    return try bound().fetchBlob(ticket: ticket, scratchDir: scratch.path, destPath: dest.path, stallMs: 0,
                                                 progress: BytesProgress(progress), cancel: cancel)
                }.value
            } onCancel: {
                cancel.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// 流式调用（#963，`timeline.subscribe`）：FFI 在自己的 runtime 上监听这条流，每帧回调 [onFrame]，
    /// 不占 Swift 线程。对端正常结束 = 返回；连接出错 = 抛 [CtrlStreamClosed]；[onFrame] 抛错 = 停流并原样抛出；
    /// 任务取消 = 停流并抛 CancellationError。
    func stream(peerToken: String, method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws {
        let client = try await Task.detached(priority: .userInitiated) { [self] in try bound() }.value
        let params = String(decoding: paramsJSON, as: UTF8.self)
        let bridge = StreamBridge(onFrame: onFrame)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                bridge.attach(c)
                do {
                    bridge.setHandle(try client.openStream(peerToken: peerToken, method: method, paramsJson: params,
                                                           connectTimeoutMs: 0, listener: bridge))
                } catch {
                    bridge.finish(error)
                }
            }
        } onCancel: {
            bridge.cancel()
        }
    }

    /// 一次请求一帧回复；返回完整 Resp 信封 JSON。
    func call(peerToken: String, method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        let params = String(decoding: paramsJSON, as: UTF8.self)
        return try await Task.detached(priority: .userInitiated) { [self] in
            let reply = try bound().call(peerToken: peerToken, method: method, paramsJson: params, timeoutMs: timeoutMs ?? 0)
            return Data(reply.utf8)
        }.value
    }
}

/// 流式调用被对端或网络结束（不是我们取消的）；[reason] 是 FFI 给的原因。
struct CtrlStreamClosed: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

/// FFI `StreamListener` → Swift continuation：`on_closed` 只来一次，continuation 只 resume 一次。
private final class StreamBridge: StreamListener, @unchecked Sendable {
    private let onFrameHandler: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: StreamHandle?
    private var cancelled = false
    private var frameError: Error?

    init(onFrame: @escaping @Sendable (Data) throws -> Void) { onFrameHandler = onFrame }

    func attach(_ c: CheckedContinuation<Void, Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    /// 取消可能早于句柄到手：到手时补一次。
    func setHandle(_ h: StreamHandle) {
        lock.lock()
        handle = h
        let stop = cancelled || frameError != nil
        lock.unlock()
        if stop { h.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let h = handle
        lock.unlock()
        h?.cancel()
    }

    func onFrame(json: String) {
        do {
            try onFrameHandler(Data(json.utf8))
        } catch {
            lock.lock()
            if frameError == nil { frameError = error }
            let h = handle
            lock.unlock()
            h?.cancel()
        }
    }

    func onClosed(error: String?) {
        lock.lock()
        let result: Error? = frameError ?? (cancelled ? CancellationError() : error.map { CtrlStreamClosed(reason: $0) })
        lock.unlock()
        finish(result)
    }

    func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
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

/// FFI 取回进度回调（数据字节数，可能来自任意线程）。
private final class BytesProgress: FetchProgress, @unchecked Sendable {
    private let handler: @Sendable (UInt64) -> Void
    init(_ handler: @escaping @Sendable (UInt64) -> Void) { self.handler = handler }
    func onBytes(bytes: UInt64) { handler(bytes) }
}
