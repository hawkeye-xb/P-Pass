// 用户主动断开（UX-06）时告诉电脑「这次配对我结束了」：断开立即完成，通知在后台尽力发一次，收到就收到，没收到就算了。
//
// 主动断开是单向行为（#956 关闭裁决，2026-10-22）：本地配对凭据清掉的那一刻断开就完成了，不留发件箱、
// 不在之后的任何时机（回前台 / 网络恢复 / 启动）重发。电脑上残留的设备行归电脑端管理（最近活动、手动移除）。
// 次序（#1239）：点确认后立刻清本地、回欢迎页，不等通知；通知所需的传输 / 地址 / 配对 id 在清理前取出、捕获进通知闭包，
// 用非结构化 Task 后台 fire-and-forget（不随界面或调用方取消），结果只写日志、不重试、不持久化。
// 配对期间的被动断开（断网、电脑重启）才需要恢复机制，那是 #976 / #977，与这里无关。
//
// - 最多等 5 秒（对位 Android `UNPAIR_NOTICE_TIMEOUT_MS` 的 withTimeoutOrNull）：FFI `call` 的 timeout_ms 只管连接 + 请求 + 应答，
//   控制面端点是第一次调用时才建的（有自己的 15 秒建端点超时），所以这里对整个调用再套一层截止，到点就不等了。
// - 带上要结束的那次配对记录的 id，电脑只在 id 一致时吊销（#565），迟到的通知不会误删新配对。
// - 日志不写 peerToken，只写 [LogRedact.id] 的 hash 前缀。
import Foundation

public enum UnpairNotice {
    public static let timeoutMs: UInt64 = 5_000

    /// `device.unpair` 的参数：旧配对没有配对 id 就不带，电脑走旧语义。
    public static func params(pairingId: String) -> [String: String] {
        pairingId.isEmpty ? [:] : ["pairing_id": pairingId]
    }

    /// 发一次，结局只写日志；任何失败都不抛。
    public static func sendOnce(_ transport: CtrlTransport, daemonNodeId: String, pairingId: String,
                                logger: CoreLogger, deadlineMs: UInt64 = timeoutMs) async {
        let tag = "desktop=\(LogRedact.id(daemonNodeId))"
        let params = params(pairingId: pairingId)
        do {
            guard let resp = try await firstWithin(deadlineMs, {
                try await ProtoClient(transport: transport).callRaw(Methods.deviceUnpair, params, timeoutMs: timeoutMs)
            }) else {
                logger.log("unpair: \(tag) no reply within \(deadlineMs) ms, not retried")
                return
            }
            if resp.ok {
                logger.log("unpair: \(tag) acknowledged")
            } else {
                logger.log("unpair: \(tag) rejected code=\(resp.error?.code ?? "?"), not retried")
            }
        } catch {
            logger.log("unpair: \(tag) unreachable (\(type(of: error))), not retried")
        }
    }

    /// [op] 在 [ms] 内的结果；到点返回 nil，不再等它（它在后台自行结束，结果没人看）。
    /// 不用 task group：group 返回前要等所有子任务，而 FFI 调用是阻塞的、取消不掉。
    static func firstWithin<T: Sendable>(_ ms: UInt64, _ op: @escaping @Sendable () async throws -> T) async throws -> T? {
        let once = OnceResult<T?>()
        return try await withCheckedThrowingContinuation { continuation in
            once.bind(continuation)
            Task { do { once.finish(.success(try await op())) } catch { once.finish(.failure(error)) } }
            Task { try? await Task.sleep(nanoseconds: ms * 1_000_000); once.finish(.success(nil)) }
        }
    }

    /// 断开的固定次序：通知丢进非结构化 `Task` 后台发（不 await），本地清理立刻执行、不等通知。
    /// [notify] 必须只依赖调用前已取出的值（清理之后原配对已不在）。通知失败、挂住、超时，
    /// 或调用方任务被取消（界面被关掉）都不影响清理，也不会取消通知。
    public static func disconnect(notify: @escaping @Sendable () async -> Void, clearLocal: () async -> Void) async {
        Task.detached { await notify() }
        await clearLocal()
    }

    /// 老版本（#956 发件箱）留在存储根的 `pending_unpair.json`：里面存着已断开电脑的 peerToken，已无读写者。
    /// 启动时删一次，不让任何凭据留在盘上。删不掉记日志（断开清单的同名行也会在下次断开时再删）。
    public static func removeLegacyOutbox(root: URL, logger: CoreLogger) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where DisconnectState.legacyUnpairOutbox.matches(name) {
            do {
                try fm.removeItem(at: root.appendingPathComponent(name))
                logger.log("unpair: removed legacy outbox file \(name)")
            } catch {
                logger.log("unpair: cannot remove legacy outbox file \(name): \(error)")
            }
        }
    }
}

/// 只认第一个结局的 continuation（截止与调用谁先到算谁）。
private final class OnceResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false

    func bind(_ c: CheckedContinuation<T, Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !done, let c = continuation else { lock.unlock(); return }
        done = true; continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}
