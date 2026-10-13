// #956：断开时电脑离线，`device.unpair` 要持久化成待撤销条目，之后每个触发点重试一次。
import Foundation
import XCTest
@testable import PPassCore

final class PendingUnpairTests: XCTestCase {
    private let day: Int64 = 86_400_000
    private let t0: Int64 = 1_800_000_000_000

    private func entry(_ node: String, token: String? = nil, epoch: String = "e1", at: Int64? = nil) -> PendingUnpair {
        PendingUnpair(daemonNodeId: node, peerToken: token ?? "token-\(node)", pairingEpoch: epoch, createdAtMs: at ?? t0)
    }

    /// 每台电脑一份脚本：按 peerToken 区分回包。
    private func make(_ dir: TempDir, now: @escaping @Sendable () -> Int64 = { 1_800_000_000_000 },
                      reply: @escaping @Sendable (String) throws -> Resp) -> (PendingUnpairStore, PendingUnpairFlusher, RecordingLogger, SentLog) {
        let logger = RecordingLogger()
        let sent = SentLog()
        let store = PendingUnpairStore(directory: dir.url, logger: logger)
        let flusher = PendingUnpairFlusher(store: store, now: now, logger: logger) { token in
            ScriptedTransport { method, params in
                sent.add(token, method, params)
                return try reply(token)
            }
        }
        return (store, flusher, logger, sent)
    }

    private let ok = Resp(id: "1", ok: true, result: .object(["unpaired": .bool(true)]))
    private func rejected(_ code: String) -> Resp { Resp(id: "1", ok: false, error: RespError(code: code, msgKey: "err.x")) }

    func testSuccessDeletesTheEntryAndSendsTheEpoch() async throws {
        let dir = TempDir()
        let (store, flusher, _, sent) = make(dir) { _ in self.ok }
        try store.enqueue(entry("A"))
        await flusher.flush()
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(sent.items.map(\.method), ["device.unpair"])
        XCTAssertEqual(sent.items[0].params, .object(["pairing_epoch": .string("e1")]))
        XCTAssertEqual(sent.items[0].token, "token-A")
    }

    func testAnEntryWithoutEpochSendsEmptyParams() async throws {
        let dir = TempDir()
        let (store, flusher, _, sent) = make(dir) { _ in self.ok }
        try store.enqueue(entry("A", epoch: ""))
        await flusher.flush()
        XCTAssertEqual(sent.items[0].params, .object([:]))
    }

    func testBeingRejectedCountsAsSuccess() async throws {
        let dir = TempDir()
        let (store, flusher, _, _) = make(dir) { _ in self.rejected(Codes.notAuthorized) }
        try store.enqueue(entry("A"))
        await flusher.flush()
        XCTAssertEqual(store.all(), [], "电脑已不认识这台手机：目的已达成")
    }

    func testOtherDesktopErrorsKeepTheEntry() async throws {
        let dir = TempDir()
        let (store, flusher, _, _) = make(dir) { _ in self.rejected(Codes.internal) }
        try store.enqueue(entry("A"))
        await flusher.flush()
        XCTAssertEqual(store.all().map(\.daemonNodeId), ["A"], "电脑内部错误不是「已撤销」，留着下次再试")
    }

    func testNetworkFailureKeepsTheEntryAndASecondFlushRetries() async throws {
        let dir = TempDir()
        let up = Flag()
        let (store, flusher, _, sent) = make(dir) { _ in
            if up.value { return self.ok }
            throw URLError(.notConnectedToInternet)
        }
        try store.enqueue(entry("A"))
        await flusher.flush()
        XCTAssertEqual(store.all().map(\.daemonNodeId), ["A"])
        up.value = true
        await flusher.flush()
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(sent.items.count, 2)
    }

    func testAnEntryOlderThanSevenDaysIsDroppedWithoutSending() async throws {
        let dir = TempDir()
        let now = Box(t0)
        let (store, flusher, logger, sent) = make(dir, now: { now.value }) { _ in self.ok }
        try store.enqueue(entry("old", at: t0))
        try store.enqueue(entry("fresh", at: t0 + 1))
        now.value = t0 + 7 * day
        await flusher.flush()
        XCTAssertEqual(sent.items.map(\.token), ["token-fresh"], "老的丢弃不发，新的照发")
        XCTAssertEqual(store.all(), [])
        XCTAssertTrue(logger.contains("expired"))
    }

    func testExpiryBoundaryIsExactlySevenDays() async throws {
        let dir = TempDir()
        let now = Box(t0)
        let (store, flusher, _, sent) = make(dir, now: { now.value }) { _ in throw URLError(.timedOut) }
        try store.enqueue(entry("A", at: t0))
        now.value = t0 + 7 * day - 1
        await flusher.flush()
        XCTAssertEqual(store.all().count, 1, "不满 7 天：保留并重试")
        XCTAssertEqual(sent.items.count, 1)
        now.value = t0 + 7 * day
        await flusher.flush()
        XCTAssertEqual(store.all(), [], "满 7 天：丢弃")
        XCTAssertEqual(sent.items.count, 1, "过期条目不再发")
    }

    func testRePairingTheSameDesktopRemovesItsEntryOnly() async throws {
        let dir = TempDir()
        let (store, flusher, _, sent) = make(dir) { _ in self.ok }
        try store.enqueue(entry("A"))
        try store.enqueue(entry("B"))
        try store.remove(daemonNodeId: "A")
        await flusher.flush()
        XCTAssertEqual(sent.items.map(\.token), ["token-B"], "A 的条目被删，不会把新配对撤掉")
    }

    func testDesktopsAreIndependent() async throws {
        let dir = TempDir()
        let (store, flusher, _, _) = make(dir) { token in
            if token == "token-A" { throw URLError(.cannotConnectToHost) }
            return self.ok
        }
        try store.enqueue(entry("A"))
        try store.enqueue(entry("B"))
        await flusher.flush()
        XCTAssertEqual(store.all().map(\.daemonNodeId), ["A"], "A 离线保留，B 成功删除，互不影响")
    }

    func testEnqueueTwiceForTheSameDesktopKeepsTheLatest() throws {
        let dir = TempDir()
        let store = PendingUnpairStore(directory: dir.url)
        try store.enqueue(entry("A", token: "old", epoch: "e1", at: t0))
        try store.enqueue(entry("A", token: "new", epoch: "e2", at: t0 + 5))
        XCTAssertEqual(store.all().map(\.peerToken), ["new"])
    }

    func testEntriesSurviveAReopenedStore() throws {
        let dir = TempDir()
        try PendingUnpairStore(directory: dir.url).enqueue(entry("A"))
        XCTAssertEqual(PendingUnpairStore(directory: dir.url).all(), [entry("A")])
    }

    func testTheTokenNeverReachesTheLog() async throws {
        let dir = TempDir()
        let (store, flusher, logger, _) = make(dir) { _ in throw URLError(.timedOut) }
        try store.enqueue(entry("A", token: "SECRET-PEER-TOKEN"))
        await flusher.flush()
        XCTAssertFalse(logger.lines.isEmpty)
        XCTAssertFalse(logger.contains("SECRET-PEER-TOKEN"))
    }

    func testAConcurrentFlushIsSkippedInsteadOfSendingTwice() async throws {
        let dir = TempDir()
        let gate = UnpairGate()
        let logger = RecordingLogger()
        let sent = SentLog()
        let store = PendingUnpairStore(directory: dir.url, logger: logger)
        let flusher = PendingUnpairFlusher(store: store, now: { 1_800_000_000_000 }, logger: logger) { token in
            GatedTransport(gate: gate) { sent.add(token, "device.unpair", .object([:])) }
        }
        try store.enqueue(entry("A"))
        let first = Task { await flusher.flush() }
        await gate.waitUntilEntered()
        await flusher.flush() // 第一轮还在飞：这一轮直接跳过
        gate.open()
        await first.value
        XCTAssertEqual(sent.items.count, 1)
    }

    func testTheManifestKeepsThePendingFileOnDisconnect() throws {
        let tmp = TempDir()
        try PendingUnpairStore(directory: tmp.url).enqueue(entry("A"))
        XCTAssertEqual(unregisteredStatePaths(root: tmp.url), [], "文件必须登记在断开清单里")
        XCTAssertEqual(DisconnectState.pendingUnpair.disposition, .keep, "断开后它必须还在：它就是断开之后要做的事")
    }
}

private final class SentLog: @unchecked Sendable {
    struct Item { let token: String; let method: String; let params: JSONValue }
    private let lock = NSLock()
    private var _items: [Item] = []
    var items: [Item] { lock.lock(); defer { lock.unlock() }; return _items }
    func add(_ token: String, _ method: String, _ params: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        _items.append(Item(token: token, method: method, params: params))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var v: Int64
    init(_ v: Int64) { self.v = v }
    var value: Int64 { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

private actor UnpairGate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        if !opened { await withCheckedContinuation { openWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    nonisolated func open() { Task { await doOpen() } }
    private func doOpen() { opened = true; openWaiters.forEach { $0.resume() }; openWaiters = [] }
}

private struct GatedTransport: CtrlTransport {
    let gate: UnpairGate
    let onCall: @Sendable () -> Void
    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        await gate.enter()
        onCall()
        return try ProtoJSON.encode(Resp(id: "1", ok: true, result: .object([:])))
    }
}
