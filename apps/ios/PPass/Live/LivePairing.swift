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
    /// #1118：验证码对不上（`pair_code_wrong` 或 `pair.status` 的 `failed`），这次申请作废。
    case codeWrong
    /// #1118：电脑的密钥确认（`confirm_b`）验不过 / 畸形的 PAKE 消息：没有保存配对。
    case desktopProofFailed

    var outcome: PairOutcome {
        switch self {
        case .accepted: return .joined(firstTime: true)
        case .denied(let note): return .refused(note: note, ownerSaidNo: true)
        case .expired: return .refused(note: .expired, ownerSaidNo: false)
        case .desktopRestarted: return .refused(note: .desktopRestarted, ownerSaidNo: false)
        case .desktopTooOld: return .needsUpdate(.desktop)
        case .versionMismatch(let side): return .needsUpdate(side)
        case .unreachable(let reason): return .failed(reason: reason)
        // 不是电脑主人拒绝的：标题用「这次加入没有完成」，原因写在说明里。
        case .codeWrong: return .refused(note: .codeWrong, ownerSaidNo: false)
        case .desktopProofFailed: return .refused(note: .desktopProofFailed, ownerSaidNo: false)
        }
    }

    /// pair.request 被拒（#1073 归类表配对通道）：版本不兼容单独成判决，其余都是「电脑那边说不」。
    static func rejected(_ error: RespError?) -> PairVerdict {
        let reason = DesktopReason(error)
        if case let .versionMismatch(side) = reasonClass(reason) { return .versionMismatch(side) }
        return .denied(PairNote(rejection: reason))
    }
}

/// #1118：手机这一半的验证码交换（PAKE）。真实现是 uniffi 的 `PairPhone`（与电脑同一份 Rust 内核），Swift 一行密码学都不写；
/// 这个协议只为让状态机能用假实现单测。
protocol PairPhoneSession: AnyObject {
    /// 放进 `pair.request.pake_a` 的 SPAKE2 消息（hex）。
    func pakeA() -> String
    /// 电脑回了 `pake_b`：返回 `confirm_a`（hex）。只能调一次。
    func finish(pakeB: String) throws -> String
    /// 电脑的 `confirm_b`：通过才能保存配对。先 finish 才能 verify。
    func verify(confirmB: String) throws
}

/// 验证码生成、指纹、PAKE 会话：全部来自 FFI。
protocol PairCrypto: Sendable {
    func generateCode() throws -> String
    func fingerprint(nodeId: String) -> String
    func start(code: String, token: String, phoneNode: String, deskNode: String) throws -> PairPhoneSession
}

extension PairPhone: PairPhoneSession {}

struct FfiPairCrypto: PairCrypto {
    func generateCode() throws -> String { try pairCodeGenerate() }
    func fingerprint(nodeId: String) -> String { nodeFingerprint(nodeId: nodeId) }
    func start(code: String, token: String, phoneNode: String, deskNode: String) throws -> PairPhoneSession {
        try PairPhone.start(code: code, token: token, phoneNode: phoneNode, deskNode: deskNode)
    }
}

/// 验证码页的显示：6 位按 3+3 分组（`123 456`）。
enum PairCodeFormat {
    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// 配对的等待循环（#1118 验证码版）：hello（查版本与能力）→ 核对电脑 → `pair.request(ack_then_poll, pake_a)` →
/// 收到 `PairSubmitted` 才显示验证码 → 每 1 秒 `pair.status`；电脑回 `pake_b` 就 finish + `pair.confirm`，
/// 回复里的 `confirm_b` 验过才算加入。连续 3 次失败判不可达；用户离开时 `pair.cancel`（桌面声明了 pair.cancel.v1 才发）。
/// 逐条对位 Android `awaitPairVerdict`。
struct PairVerdictLoop {
    /// 返回完整 Resp；连不上时抛。
    let rpc: (String, Encodable) async throws -> Resp
    /// 验证码页的轮询间隔（owner 拍板：只在显示验证码这一步加快，原来 5 秒）。别处不共用。
    static let codePollIntervalNs: UInt64 = 1_000_000_000

    var pollIntervalNs: UInt64 = Self.codePollIntervalNs
    var maxConsecutiveFailures = 3
    var sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    var crypto: PairCrypto = FfiPairCrypto()
    /// 本机 NodeId（64 hex）与二维码里的电脑 NodeId：PAKE 的两端身份。
    var phoneNode = ""
    var deskNode = ""
    /// 提交成功后才调。
    var onCode: PairCodeSink = { _ in }
    /// 电脑名拿不到时的兜底名。
    var fallbackDesktopName = L.s("storage_device_default")

    static let statusCapability = "pair.status.v1"
    static let cancelCapability = "pair.cancel.v1"

    init(rpc: @escaping (String, Encodable) async throws -> Resp) { self.rpc = rpc }

    func run(token: String, deviceName: String) async throws -> PairVerdict {
        let hello: Resp
        do { hello = try await rpc(Methods.hello, EmptyParams()) } catch { return .unreachable(String(describing: error)) }
        var mayWithdraw = true
        var desktopName = ""
        // #1069：版本在握手时判定——不兼容就不发起配对请求，直接提示更新哪一端。
        if !hello.ok, let side = hello.outdatedSide { return .versionMismatch(side) }
        if hello.ok {
            let decoded = try? hello.result?.decode(Hello.self)
            let caps = decoded?.capabilities ?? []
            if !caps.contains(Self.statusCapability) { return .desktopTooOld }
            mayWithdraw = caps.contains(Self.cancelCapability)
            desktopName = decoded?.deviceName ?? ""
        }
        // 扫码之后不问「要连接吗」，直接发起：电脑名与标识放到验证码页上。标识由本机从二维码的 NodeId 算，不取电脑说的任何东西。
        let info = PairDesktopInfo(name: desktopName.isEmpty ? fallbackDesktopName : desktopName,
                                   fingerprint: crypto.fingerprint(nodeId: deskNode))
        try Task.checkCancellation()

        let code: String
        let phone: PairPhoneSession
        do {
            code = try crypto.generateCode()
            phone = try crypto.start(code: code, token: token, phoneNode: phoneNode, deskNode: deskNode)
        } catch { return .unreachable("pake: \(error)") }
        let submit: Resp
        do {
            submit = try await rpc(Methods.pairRequest, PairRequest(token: token, deviceName: deviceName, ackThenPoll: true, pakeA: phone.pakeA()))
        } catch { return .unreachable(String(describing: error)) }
        guard submit.ok else { return .rejected(submit.error) }
        // 没有 request_id 的应答（老电脑直接回 accepted）不带验证码交换：绝不当作加入。
        guard let submitted = try? submit.result?.decode(PairSubmitted.self), !submitted.requestId.isEmpty else {
            return .desktopTooOld
        }
        // 只有提交成功之后才显示验证码；被拒的提交（上面的 return）绝不会走到这里。
        await onCode(PairCodeShown(code: code, desktop: info, phoneNode: phoneNode))
        let ttl = submitted.ttlMs > 0 ? UInt64(submitted.ttlMs) : 600_000
        let intervalMs = pollIntervalNs / 1_000_000
        let maxPolls = (ttl + intervalMs - 1) / max(intervalMs, 1) + 1
        let query = PairStatusRequest(requestId: submitted.requestId)
        do {
            return try await poll(query, phone: phone, maxPolls: maxPolls)
        } catch is CancellationError {
            if mayWithdraw { _ = try? await rpc(Methods.pairCancel, query) }
            throw CancellationError()
        }
    }

    /// `confirm_b` 验过才给出已加入；缺 `confirm_b` 由调用方按畸形回复计失败。
    private func verified(_ phone: PairPhoneSession, _ reply: PairStatusReply) -> PairVerdict? {
        guard let accepted = reply.accepted, !accepted.pairingId.isEmpty,
              let confirmB = reply.confirmB, !confirmB.isEmpty else { return nil }
        do { try phone.verify(confirmB: confirmB) } catch { return .desktopProofFailed }
        return .accepted(accepted)
    }

    private func poll(_ query: PairStatusRequest, phone: PairPhoneSession, maxPolls: UInt64) async throws -> PairVerdict {
        var failures = 0
        var lastFailure = ""
        var confirmA: String?
        for _ in 0..<maxPolls {
            try await sleep(pollIntervalNs)
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
            // 这一轮有没有失败：要等整轮（状态 + 需要时的 pair.confirm）都成功才清零连续失败计数。
            var roundFailed = false
            switch reply.state {
            case "accepted":
                // 例如 pair.confirm 的回复丢了：电脑已接受，confirm_b 随状态回来；没带 / 还没 finish 都是畸形回复。
                if confirmA != nil, let verdict = verified(phone, reply) { return verdict }
                roundFailed = true
                lastFailure = "pair.status: accepted without usable confirm_b"
            case "pending":
                if confirmA == nil, let pakeB = reply.pakeB, !pakeB.isEmpty {
                    do { confirmA = try phone.finish(pakeB: pakeB) } catch { return .desktopProofFailed }
                }
                // 已 finish：每轮都发（同一个 confirm_a，电脑侧幂等），回复丢了 / 网络断了下一轮自然重发。
                if let confirmA {
                    let outcome = await confirm(PairConfirmRequest(requestId: query.requestId, confirmA: confirmA), phone: phone)
                    switch outcome {
                    case .verdict(let verdict): return verdict
                    case .failed(let why): roundFailed = true; lastFailure = why
                    }
                }
            // v2 的 denied 不带说明（#1070），本端自己说（#1072 §5）。
            case "denied": return .denied(.denied)
            case "expired": return .expired
            case "not_found": return .desktopRestarted
            case "failed": return .codeWrong
            default: break
            }
            if roundFailed {
                failures += 1
                if failures >= maxConsecutiveFailures { return .unreachable(lastFailure) }
            } else {
                failures = 0
            }
        }
        return .expired
    }

    private enum ConfirmOutcome { case verdict(PairVerdict), failed(String) }

    private func confirm(_ request: PairConfirmRequest, phone: PairPhoneSession) async -> ConfirmOutcome {
        do {
            let r = try await rpc(Methods.pairConfirm, request)
            if !r.ok {
                let reason = DesktopReason(r.error)
                if reason == .registered(.pairCodeWrong) { return .verdict(.codeWrong) }
                return .failed("pair.confirm: \(reason)")
            }
            guard let reply = try r.result?.decode(PairStatusReply.self), reply.state == "accepted" else {
                return .failed("pair.confirm: unexpected reply")
            }
            guard let verdict = verified(phone, reply) else { return .failed("pair.confirm: accepted without usable confirm_b") }
            return .verdict(verdict)
        } catch {
            return .failed(String(describing: error))
        }
    }
}

struct EmptyParams: Codable {}

/// 真实配对服务：解析串 → 已是成员就直接回来（换了地址的老手机）→ 否则走等待循环 → 存配对记录。
final class LivePairing: PairingService, @unchecked Sendable {
    private let transportFor: (String) -> CtrlTransport
    private let store: PairingStore
    private let onboarded: (String) -> Bool
    /// 返回 true = 配对已落盘、但有设置没写下来要提示用户（#1039：换新电脑清旧的后台备份意图失败）。
    private let onPaired: (PairingRecord, _ knownDesktop: Bool) -> Bool
    private let onDisconnect: () async -> Void
    private let logger: CoreLogger
    private let crypto: PairCrypto
    /// 本机 NodeId（64 hex）：PAKE 里手机一端的身份。
    private let localNodeId: () throws -> String
    private var current: Task<PairVerdict, Error>?

    init(transportFor: @escaping (String) -> CtrlTransport, store: PairingStore, onboarded: @escaping (String) -> Bool,
         onPaired: @escaping (PairingRecord, _ knownDesktop: Bool) -> Bool, onDisconnect: @escaping () async -> Void,
         logger: CoreLogger, localNodeId: @escaping () throws -> String, crypto: PairCrypto = FfiPairCrypto()) {
        self.localNodeId = localNodeId
        self.crypto = crypto
        self.transportFor = transportFor
        self.logger = logger
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

    func pair(code raw: String, onCode: @escaping PairCodeSink) async -> PairOutcome {
        let code: ParsedPairLink
        do { code = try parsePairLink(link: raw.trimmingCharacters(in: .whitespacesAndNewlines)) } catch {
            return .failed(reason: L.s("not_a_code") + " (\(error))")
        }

        let client = ProtoClient(transport: transportFor(code.peerToken))
        let rpc: (String, Encodable) async throws -> Resp = { method, params in
            try await client.callRaw(method, AnyEncodable(params), timeoutMs: 15_000)
        }
        // 已是这台电脑的成员（电脑换了地址 / 身份）：hello 对成员带回非空 pairing_id，未配对（含配对记录已被电脑删除）的设备拿不到
        // （这类 hello 直接被拒 not_paired），语义对位 Android（#1051）。hello 超时 / 被拒 / 没带 pairingId 都落回正常配对，
        // 不存空 pairingId / 空电脑名（#970）。
        let member = await memberHello(rpc)
        if case let .outdated(side) = member { return PairVerdict.versionMismatch(side).outcome }
        if case let .hello(hello) = member, let pairingId = hello.pairingId, !pairingId.isEmpty {
            // 「连没连过」必须在 save 之前定：save 里的 onPaired 会把这台标成连过（#982：之前顺序反了，firstTime 恒为 false）。
            let known = onboarded(code.nodeId)
            do {
                let settingSaveFailed = try save(code, name: hello.deviceName, pairingId: pairingId, known: known)
                return .joined(firstTime: !known, settingSaveFailed: settingSaveFailed)
            } catch {
                return saveFailure(error)
            }
        }
        let phoneNode: String
        do { phoneNode = try localNodeId() } catch { return .failed(reason: "local node id: \(error)") }
        var loop = PairVerdictLoop(rpc: rpc)
        loop.crypto = crypto
        loop.phoneNode = phoneNode
        loop.deskNode = code.nodeId
        loop.onCode = onCode
        // 发给电脑的本机名直接用系统名。iOS 16 起没有 com.apple.developer.device-information.user-assigned-device-name 权限时
        // 这里只给「iPhone」；苹果批下这项权限后，在 PPass.entitlements 加上它即可读到用户在系统里起的名字，这里不用改代码。
        let task = Task { [loop] in try await loop.run(token: code.token, deviceName: UIDevice.current.name) }
        current = task
        let verdict: PairVerdict
        do { verdict = try await task.value } catch { return .failed(reason: String(describing: error)) }
        if case .accepted(let a) = verdict {
            let known = onboarded(code.nodeId)
            do {
                let settingSaveFailed = try save(code, name: a.storageDeviceName, pairingId: a.pairingId, known: known)
                return .joined(firstTime: !known, settingSaveFailed: settingSaveFailed)
            } catch { return saveFailure(error) }
        }
        return verdict.outcome
    }

    func cancel() async { current?.cancel() }

    /// 主动断开（对位 Android onDisconnect）：清配对前尽力通知电脑一次（5 秒），失败就算了，然后无条件清本地。
    /// 不留任何东西待以后重发（#956 关闭裁决）。配对已失效（lost）的电脑本就不认这台手机，不发。
    func disconnect() async {
        let record = store.load()
        let transportFor = self.transportFor, logger = self.logger
        await UnpairNotice.disconnect(
            notify: {
                guard let r = record, !r.lost else { return }
                await UnpairNotice.sendOnce(transportFor(r.peerToken), daemonNodeId: r.daemonNodeId,
                                            pairingId: r.pairingId, logger: logger)
            },
            clearLocal: onDisconnect)
    }

    /// 不通知电脑，直接按断开清单清本地（与被拒即清理同一份）。
    func clearLocal() async { await onDisconnect() }

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
    /// 返回 `onPaired` 的结果：配对之后的设置有没有没写下来、要提示的（#1039）。
    private func save(_ code: ParsedPairLink, name: String, pairingId: String, known: Bool) throws -> Bool {
        let record = PairingRecord(daemonNodeId: code.nodeId, peerToken: code.peerToken, storageDeviceName: name,
                                   pairedAt: Int64(Date().timeIntervalSince1970 * 1000), pairingId: pairingId)
        try store.save(record)
        return onPaired(record, known)
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
