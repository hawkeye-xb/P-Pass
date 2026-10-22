import Foundation
import PPassCore
import XCTest
@testable import PPass

/// #1118 的假 PAKE 会话：记录调用顺序，finish / verify 的结果可配置。
final class FakePairSession: PairPhoneSession, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var pake = "41" + String(repeating: "aa", count: 32)
    var confirmA = "c1" + String(repeating: "11", count: 31)
    var finishError: Error?
    var verifyError: Error?

    struct Failure: Error {}

    func pakeA() -> String { pake }

    func finish(pakeB: String) throws -> String {
        lock.lock(); log.append("finish:\(pakeB)"); lock.unlock()
        if let finishError { throw finishError }
        return confirmA
    }

    func verify(confirmB: String) throws {
        lock.lock(); log.append("verify:\(confirmB)"); lock.unlock()
        if let verifyError { throw verifyError }
    }
}

/// 假的验证码 / 指纹 / 会话工厂（真实现来自 FFI，见 `FfiPairCrypto`）。
final class FakePairCrypto: PairCrypto, @unchecked Sendable {
    let session = FakePairSession()
    var code = "123456"
    private let lock = NSLock()
    private var started: [(code: String, token: String, phone: String, desk: String)] = []
    var starts: [(code: String, token: String, phone: String, desk: String)] { lock.lock(); defer { lock.unlock() }; return started }

    func generateCode() throws -> String { code }
    /// 指纹随传进来的 NodeId 变：测试靠它证明「指纹是用二维码 node 算的」。
    func fingerprint(nodeId: String) -> String { "FP-" + nodeId.prefix(8) }
    static func expectedFingerprint(_ nodeId: String) -> String { "FP-" + nodeId.prefix(8) }
    func start(code: String, token: String, phoneNode: String, deskNode: String) throws -> PairPhoneSession {
        lock.lock(); started.append((code, token, phoneNode, deskNode)); lock.unlock()
        return session
    }
}

/// 按方法名回放应答序列的假电脑：同一方法按顺序出队，最后一条重复；`.fail` = 连不上（抛）；未登记的方法 = 连不上。
final class FakeDesk: @unchecked Sendable {
    enum Step {
        case resp(Resp), fail
        static func ok(_ value: some Encodable) throws -> Step { .resp(Resp(ok: true, result: try JSONValue.from(value))) }
        static func err(_ code: String, _ reason: String) -> Step { .resp(Resp(ok: false, error: RespError(code: code, reason: reason))) }
    }
    struct Unreachable: Error {}

    private let lock = NSLock()
    private var queues: [String: [Step]]
    private(set) var calls: [(method: String, params: Encodable)] = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.method) }

    init(_ queues: [String: [Step]]) { self.queues = queues }

    func params<T>(_ method: String, as type: T.Type) -> [T] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.method == method }.compactMap { $0.params as? T }
    }

    func rpc(_ method: String, _ params: Encodable) async throws -> Resp {
        let step: Step? = {
            lock.lock(); defer { lock.unlock() }
            calls.append((method, params))
            guard var q = queues[method], !q.isEmpty else { return nil }
            let head = q[0]
            if q.count > 1 { q.removeFirst(); queues[method] = q }
            return head
        }()
        switch step {
        case .resp(let r): return r
        case .fail, .none: throw Unreachable()
        }
    }
}

enum PairFixtures {
    static let phoneNode = String(repeating: "a", count: 64)
    static let deskNode = String(repeating: "b", count: 64)
    static let pakeB = "42" + String(repeating: "bb", count: 32)
    static let confirmB = "cb" + String(repeating: "22", count: 31)

    static func hello(name: String = "Home Mac", pairingId: String? = nil) throws -> FakeDesk.Step {
        try .ok(Hello(capabilities: [PairVerdictLoop.statusCapability, PairVerdictLoop.cancelCapability], deviceName: name, pairingId: pairingId))
    }
    static func submitted(ttlMs: Int64 = 600_000) throws -> FakeDesk.Step { try .ok(PairSubmitted(accepted: true, requestId: "r1", ttlMs: ttlMs)) }
    static func pending(pakeB: String? = nil) throws -> FakeDesk.Step { try .ok(PairStatusReply(state: "pending", pakeB: pakeB)) }
    static func confirmed(confirmB: String? = PairFixtures.confirmB, pairingId: String = "e1") throws -> FakeDesk.Step {
        try .ok(PairStatusReply(state: "accepted", accepted: PairAccepted(storageDeviceName: "Home Mac", pairingId: pairingId), confirmB: confirmB))
    }

    /// 测试用的验证码状态机：1ms 间隔、假 PAKE、核对步骤可注入。
    static func loop(_ desk: FakeDesk, crypto: FakePairCrypto = FakePairCrypto(),
                     review: @escaping PairReview = { _ in true }, onCode: @escaping PairCodeSink = { _ in }) -> PairVerdictLoop {
        var l = PairVerdictLoop(rpc: { try await desk.rpc($0, $1) })
        l.pollIntervalNs = 1_000_000
        l.crypto = crypto
        l.phoneNode = phoneNode
        l.deskNode = deskNode
        l.review = review
        l.onCode = onCode
        return l
    }
}

/// 线程安全的计数 / 记录盒子（给 @Sendable 闭包用）。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
