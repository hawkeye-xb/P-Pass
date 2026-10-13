import Foundation
import PPassCore
import PPassTransport
import UIKit

/// 配对结局的判决（对位 Android `PairVerdict`）。
enum PairVerdict: Equatable {
    case accepted(PairAccepted)
    case denied(msgKey: String)
    case expired, desktopRestarted, desktopTooOld
    case unreachable(String)

    var outcome: PairOutcome {
        switch self {
        case .accepted: return .joined(firstTime: true)
        case .denied(let key): return .refused(msgKey: key, ownerSaidNo: true)
        case .expired: return .refused(msgKey: "err.pair_expired", ownerSaidNo: false)
        case .desktopRestarted: return .refused(msgKey: "err.pair_restarted", ownerSaidNo: false)
        case .desktopTooOld: return .refused(msgKey: "err.unsupported", ownerSaidNo: false)
        case .unreachable(let reason): return .failed(reason: reason)
        }
    }
}

/// NET-10 的等待循环：hello（查能力）→ `pair.request(ack_then_poll)` → 每 5 秒 `pair.status`，
/// 连续 3 次失败判不可达；用户离开时 `pair.cancel`（桌面声明了 pair.cancel.v1 才发）。逐条对位 Android `awaitPairVerdict`。
struct PairVerdictLoop {
    /// 返回完整 Resp；连不上时抛。
    let rpc: (String, Encodable) async throws -> Resp
    var pollIntervalNs: UInt64 = 5_000_000_000
    var maxConsecutiveFailures = 3

    static let statusCapability = "pair.status.v1"
    static let cancelCapability = "pair.cancel.v1"

    func run(token: String, deviceName: String) async throws -> PairVerdict {
        let hello: Resp
        do { hello = try await rpc(Methods.hello, EmptyParams()) } catch { return .unreachable(String(describing: error)) }
        var mayWithdraw = true
        if hello.ok {
            let caps = (try? hello.result?.decode(Hello.self))?.capabilities ?? []
            if !caps.contains(Self.statusCapability) { return .desktopTooOld }
            mayWithdraw = caps.contains(Self.cancelCapability)
        }
        let submit: Resp
        do {
            submit = try await rpc(Methods.pairRequest, PairRequest(token: token, deviceName: deviceName, ackThenPoll: true))
        } catch { return .unreachable(String(describing: error)) }
        guard submit.ok else { return .denied(msgKey: submit.error?.msgKey ?? "err.not_authorized") }
        guard let submitted = try? submit.result?.decode(PairSubmitted.self), !submitted.requestId.isEmpty else {
            if let legacy = try? submit.result?.decode(PairAccepted.self), !legacy.pairingEpoch.isEmpty { return .accepted(legacy) }
            return .desktopTooOld
        }
        let ttl = submitted.ttlMs > 0 ? UInt64(submitted.ttlMs) : 600_000
        let intervalMs = pollIntervalNs / 1_000_000
        let maxPolls = (ttl + intervalMs - 1) / max(intervalMs, 1) + 1
        let query = PairStatusRequest(requestId: submitted.requestId)
        do {
            return try await poll(query, maxPolls: maxPolls)
        } catch is CancellationError {
            if mayWithdraw { _ = try? await rpc(Methods.pairCancel, query) }
            throw CancellationError()
        }
    }

    private func poll(_ query: PairStatusRequest, maxPolls: UInt64) async throws -> PairVerdict {
        var failures = 0
        var lastFailure = ""
        for _ in 0..<maxPolls {
            try await Task.sleep(nanoseconds: pollIntervalNs)
            var reply: PairStatusReply?
            do {
                let r = try await rpc(Methods.pairStatus, query)
                if r.ok { reply = try r.result?.decode(PairStatusReply.self) } else { lastFailure = "pair.status: \(r.error?.msgKey ?? "")" }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = String(describing: error)
            }
            guard let reply else {
                failures += 1
                if failures >= maxConsecutiveFailures { return .unreachable(lastFailure) }
                continue
            }
            failures = 0
            switch reply.state {
            case "accepted":
                if let a = reply.accepted, !a.pairingEpoch.isEmpty { return .accepted(a) }
                failures += 1
                lastFailure = "pair.status: accepted without payload"
                if failures >= maxConsecutiveFailures { return .unreachable(lastFailure) }
            case "denied": return .denied(msgKey: reply.msgKey ?? "err.not_authorized")
            case "expired": return .expired
            case "not_found": return .desktopRestarted
            default: break
            }
        }
        return .expired
    }
}

struct EmptyParams: Codable {}

/// 真实配对服务：解析串 → 已是成员就直接回来（换了地址的老手机）→ 否则走等待循环 → 存配对记录。
final class LivePairing: PairingService, @unchecked Sendable {
    private let plane: ControlPlane
    private let store: PairingStore
    private let onboarded: (String) -> Bool
    private let onPaired: (PairingRecord) -> Void
    private let onDisconnect: () async -> Void
    private let pending: PendingUnpairStore
    private let flusher: PendingUnpairFlusher
    private var current: Task<PairVerdict, Error>?

    init(plane: ControlPlane, store: PairingStore, onboarded: @escaping (String) -> Bool,
         onPaired: @escaping (PairingRecord) -> Void, onDisconnect: @escaping () async -> Void,
         pending: PendingUnpairStore, flusher: PendingUnpairFlusher) {
        self.plane = plane
        self.pending = pending
        self.flusher = flusher
        self.store = store
        self.onboarded = onboarded
        self.onPaired = onPaired
        self.onDisconnect = onDisconnect
    }

    func pairedAtMs() -> Int64? { store.load().map(\.pairedAt).flatMap { $0 > 0 ? $0 : nil } }

    func status() -> PairingStatus {
        guard let r = store.load() else { return .notPaired }
        let name = r.storageDeviceName.isEmpty ? L.s("storage_device_default") : r.storageDeviceName
        return r.lost ? .lost(desktopName: name) : .paired(desktopName: name)
    }

    func pair(code raw: String) async -> PairOutcome {
        let code: ParsedPairLink
        do { code = try parsePairLink(link: raw.trimmingCharacters(in: .whitespacesAndNewlines)) } catch {
            return .failed(reason: L.s("not_a_code") + " (\(error))")
        }

        let client = ProtoClient(transport: PeerCtrlTransport(plane: plane, peerToken: code.peerToken))
        let rpc: (String, Encodable) async throws -> Resp = { method, params in
            try await client.callRaw(method, AnyEncodable(params), timeoutMs: 15_000)
        }
        // 已是这台电脑的成员（电脑换了地址 / 身份）：backup.begin 只认成员，ok 就不必再申请。
        if let probe = try? await rpc(Methods.backupBegin, EmptyParams()), probe.ok {
            let hello = try? await rpc(Methods.hello, EmptyParams()).result?.decode(Hello.self)
            save(code, name: hello?.deviceName ?? "", epoch: hello?.pairingEpoch ?? "")
            return .joined(firstTime: !onboarded(code.nodeId))
        }
        let task = Task { try await PairVerdictLoop(rpc: rpc).run(token: code.token, deviceName: UIDevice.current.name) }
        current = task
        let verdict: PairVerdict
        do { verdict = try await task.value } catch { return .failed(reason: String(describing: error)) }
        if case .accepted(let a) = verdict {
            save(code, name: a.storageDeviceName, epoch: a.pairingEpoch)
            return .joined(firstTime: !onboarded(code.nodeId))
        }
        return verdict.outcome
    }

    func cancel() async { current?.cancel() }

    /// unpair 只是尽力通知（电脑关机 / 已吊销都不能卡住本地断开），本地清理永远执行。
    /// #956：先把「待撤销」条目落盘，再试发一次，最后才清配对——发不出去的由前台 / 网络恢复 / 启动时的重试接手。
    func disconnect() async {
        if let r = store.load(), !r.lost {
            let entry = PendingUnpair(daemonNodeId: r.daemonNodeId, peerToken: r.peerToken, pairingEpoch: r.pairingEpoch,
                                      createdAtMs: Int64(Date().timeIntervalSince1970 * 1000))
            do {
                try pending.enqueue(entry)
                await flusher.flush()
            } catch {
                AppLog.log("unpair-outbox: enqueue failed (\(error)); sending once without persistence")
                await flusher.attempt(entry)
            }
        }
        await onDisconnect()
    }

    private func save(_ code: ParsedPairLink, name: String, epoch: String) {
        let record = PairingRecord(daemonNodeId: code.nodeId, peerToken: code.peerToken, storageDeviceName: name,
                                   pairedAt: Int64(Date().timeIntervalSince1970 * 1000), pairingEpoch: epoch)
        store.save(record)
        onPaired(record)
    }
}

/// `pairing.json`（存储根目录）。
final class PairingStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(root: URL) { url = root.appendingPathComponent("pairing.json") }

    func load() -> PairingRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PairingRecord.self, from: data)
    }

    func save(_ r: PairingRecord) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: url, options: .atomic) }
    }

    func markLost() {
        guard var r = load(), !r.lost else { return }
        r.lost = true
        save(r)
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
