import Foundation
import PPassCore
import PPassTransport
import UIKit

/// 配对结局的判决（对位 Android `PairVerdict`）。
enum PairVerdict: Equatable {
    case accepted(PairAccepted)
    /// 电脑那边说不：pair.status 的 `denied`，或 pair.request 被拒（note 按 `reason` 本端挑）。
    case denied(PairNote)
    case expired, desktopRestarted, desktopTooOld
    /// #1069：协议版本不兼容（`VERSION_MISMATCH`）。不是电脑主人拒绝的，提示更新。
    case versionMismatch(OutdatedSide)
    case unreachable(String)

    var outcome: PairOutcome {
        switch self {
        case .accepted: return .joined(firstTime: true)
        case .denied(let note): return .refused(note: note, ownerSaidNo: true)
        case .expired: return .refused(note: .expired, ownerSaidNo: false)
        case .desktopRestarted: return .refused(note: .desktopRestarted, ownerSaidNo: false)
        case .desktopTooOld: return .needsUpdate(.desktop)
        case .versionMismatch(let side): return .needsUpdate(side)
        case .unreachable(let reason): return .failed(reason: reason)
        }
    }

    /// pair.request 被拒（#1073 归类表配对通道）：版本不兼容单独成判决，其余都是「电脑那边说不」。
    static func rejected(_ error: RespError?) -> PairVerdict {
        let reason = DesktopReason(error)
        if case let .versionMismatch(side) = reasonClass(reason) { return .versionMismatch(side) }
        return .denied(PairNote(rejection: reason))
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
        // #1069：版本在握手时判定——不兼容就不发起配对请求，直接提示更新哪一端。
        if !hello.ok, let side = hello.outdatedSide { return .versionMismatch(side) }
        if hello.ok {
            let caps = (try? hello.result?.decode(Hello.self))?.capabilities ?? []
            if !caps.contains(Self.statusCapability) { return .desktopTooOld }
            mayWithdraw = caps.contains(Self.cancelCapability)
        }
        let submit: Resp
        do {
            submit = try await rpc(Methods.pairRequest, PairRequest(token: token, deviceName: deviceName, ackThenPoll: true))
        } catch { return .unreachable(String(describing: error)) }
        guard submit.ok else { return .rejected(submit.error) }
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
                if r.ok { reply = try r.result?.decode(PairStatusReply.self) } else { lastFailure = "pair.status: \(DesktopReason(r.error))" }
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
            // v2 的 denied 不带说明（#1070），本端自己说（#1072 §5）。
            case "denied": return .denied(.denied)
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
    private let transportFor: (String) -> CtrlTransport
    private let store: PairingStore
    private let onboarded: (String) -> Bool
    private let onPaired: (PairingRecord, _ knownDesktop: Bool) -> Void
    private let onDisconnect: () async -> Void
    private let pending: PendingUnpairStore
    private let flusher: PendingUnpairFlusher
    private var current: Task<PairVerdict, Error>?

    init(transportFor: @escaping (String) -> CtrlTransport, store: PairingStore, onboarded: @escaping (String) -> Bool,
         onPaired: @escaping (PairingRecord, _ knownDesktop: Bool) -> Void, onDisconnect: @escaping () async -> Void,
         pending: PendingUnpairStore, flusher: PendingUnpairFlusher) {
        self.transportFor = transportFor
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

        let client = ProtoClient(transport: transportFor(code.peerToken))
        let rpc: (String, Encodable) async throws -> Resp = { method, params in
            try await client.callRaw(method, AnyEncodable(params), timeoutMs: 15_000)
        }
        // 已是这台电脑的成员（电脑换了地址 / 身份）：hello 对成员带回非空 pairing_epoch，未配对 / 已撤销的设备拿不到
        // （已撤销的 hello 直接被拒），语义对位 Android（#1051）。hello 超时 / 被拒 / 没带 epoch 都落回正常配对，
        // 不存空 epoch / 空电脑名（#970）。
        let member = await memberHello(rpc)
        if case let .outdated(side) = member { return PairVerdict.versionMismatch(side).outcome }
        if case let .hello(hello) = member, let epoch = hello.pairingEpoch, !epoch.isEmpty {
            // 「连没连过」必须在 save 之前定：save 里的 onPaired 会把这台标成连过（#982：之前顺序反了，firstTime 恒为 false）。
            let known = onboarded(code.nodeId)
            do { try save(code, name: hello.deviceName, epoch: epoch, known: known) } catch {
                return saveFailure(error)
            }
            return .joined(firstTime: !known)
        }
        let task = Task { try await PairVerdictLoop(rpc: rpc).run(token: code.token, deviceName: UIDevice.current.name) }
        current = task
        let verdict: PairVerdict
        do { verdict = try await task.value } catch { return .failed(reason: String(describing: error)) }
        if case .accepted(let a) = verdict {
            let known = onboarded(code.nodeId)
            do { try save(code, name: a.storageDeviceName, epoch: a.pairingEpoch, known: known) } catch { return saveFailure(error) }
            return .joined(firstTime: !known)
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

    private enum MemberHello { case hello(Hello), outdated(OutdatedSide), none }

    private func memberHello(_ rpc: (String, Encodable) async throws -> Resp) async -> MemberHello {
        do {
            let reply = try await rpc(Methods.hello, EmptyParams())
            if !reply.ok, let side = reply.outdatedSide {
                AppLog.log("pair: hello says the \(side.rawValue) is outdated; not pairing")
                return .outdated(side)
            }
            guard reply.ok, let hello = try reply.result?.decode(Hello.self) else {
                AppLog.log("pair: member fast path hello gave no usable result (ok=\(reply.ok)); falling back to pairing")
                return .none
            }
            return .hello(hello)
        } catch {
            AppLog.log("pair: member fast path hello failed (\(error)); falling back to pairing")
            return .none
        }
    }

    /// 写盘成功才算配对成功：失败不调 `onPaired`，让用户看到失败而不是进入重启即丢的「已配对」（#969）。
    private func save(_ code: ParsedPairLink, name: String, epoch: String, known: Bool) throws {
        let record = PairingRecord(daemonNodeId: code.nodeId, peerToken: code.peerToken, storageDeviceName: name,
                                   pairedAt: Int64(Date().timeIntervalSince1970 * 1000), pairingEpoch: epoch)
        try store.save(record)
        onPaired(record, known)
    }

    private func saveFailure(_ error: Error) -> PairOutcome {
        AppLog.log("pair: cannot persist pairing.json (\(error))")
        return .failed(reason: L.s("pair_save_failed") + " (\(error))")
    }
}

/// `pairing.json`（存储根目录）。写盘失败抛出（对位 Android `PairingStore.save` 的 `check(rename)`，#969）；
/// 读到损坏文件记日志后按未配对处理，与「文件不存在」可区分。
final class PairingStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let log: @Sendable (String) -> Void

    init(root: URL, log: @escaping @Sendable (String) -> Void = { AppLog.log($0) }) {
        url = root.appendingPathComponent("pairing.json")
        self.log = log
    }

    func load() -> PairingRecord? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    func save(_ r: PairingRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try saveLocked(r)
    }

    /// 同一把锁里读改写（引擎回调与 UI 线程会并发改配对记录）。没有配对记录时返回 false、什么都不写。
    @discardableResult
    func update(_ change: (inout PairingRecord) -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var r = loadLocked() else { return false }
        let before = r
        change(&r)
        if r != before { try saveLocked(r) }
        return true
    }

    func markLost() throws {
        try update { $0.lost = true }
    }

    private func loadLocked() -> PairingRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(PairingRecord.self, from: try Data(contentsOf: url))
        } catch {
            log("pairing.json unreadable, treated as not paired: \(error)")
            return nil
        }
    }

    private func saveLocked(_ r: PairingRecord) throws {
        try JSONEncoder().encode(r).write(to: url, options: .atomic)
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
