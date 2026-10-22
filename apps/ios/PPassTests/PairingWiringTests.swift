import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

private final class LogSink: @unchecked Sendable, CoreLogger {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func log(_ message: String) { lock.lock(); stored.append(message); lock.unlock() }
}

/// 按方法名回放应答的控制面假传输；方法没登记 = 连不上（抛）。
private final class ScriptedTransport: CtrlTransport, @unchecked Sendable {
    enum Reply {
        case resp(Resp), fail
        static func ok(_ value: some Encodable) throws -> Reply { .resp(Resp(ok: true, result: try JSONValue.from(value))) }
    }
    private let lock = NSLock()
    private var replies: [String: Reply]
    private(set) var calls: [String] = []
    struct Unreachable: Error {}

    init(_ replies: [String: Reply]) { self.replies = replies }

    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        lock.lock(); calls.append(method); let reply = replies[method]; lock.unlock()
        switch reply {
        case .resp(let r): return try ProtoJSON.encode(r)
        case .fail, .none: throw Unreachable()
        }
    }
}

/// #969 / #970：配对记录的写盘与「已是成员」快路径。
final class PairingWiringTests: XCTestCase {
    private var dir: URL!
    private var link = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 合法 NodeId 必须是曲线上的点：借一个离线控制面端点的（同 TransportFFITests）。
        let client = try CtrlClient.bind(config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.close() }
        link = "ppf://pair?node=\(try client.nodeId())&t=deadbeef"
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func record(pairingId: String = "e1", lost: Bool = false) -> PairingRecord {
        PairingRecord(daemonNodeId: "d", peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingId: pairingId, lost: lost)
    }

    private func makePairing(_ transport: ScriptedTransport, store: PairingStore,
                             onboarded: @escaping (String) -> Bool = { _ in false },
                             onPaired: @escaping (PairingRecord, Bool) -> Bool = { _, _ in false }) -> LivePairing {
        LivePairing(transportFor: { _ in transport }, store: store, onboarded: onboarded, onPaired: onPaired,
                    onDisconnect: {}, logger: LogSink())
    }

    private func makeDisconnecting(_ transport: ScriptedTransport, store: PairingStore,
                                   onDisconnect: @escaping () async -> Void) -> LivePairing {
        LivePairing(transportFor: { _ in transport }, store: store, onboarded: { _ in false }, onPaired: { _, _ in false },
                    onDisconnect: onDisconnect, logger: LogSink())
    }

    /// 把 pairing.json 占成一个目录：原子写必然失败（不依赖权限、不依赖磁盘满）。
    private func blockPairingFile() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("pairing.json"), withIntermediateDirectories: false)
    }

    // MARK: PairingStore（#969）

    func test_save_throws_when_the_file_cannot_be_written() throws {
        let store = PairingStore(root: dir)
        try blockPairingFile()
        XCTAssertThrowsError(try store.save(record()))
    }

    func test_load_of_a_corrupt_file_logs_and_is_distinguishable_from_missing() throws {
        let logs = LogSink()
        let store = PairingStore(root: dir, log: { logs.log($0) })
        XCTAssertNil(store.load())
        XCTAssertTrue(logs.lines.isEmpty, "文件不存在是正常的未配对，不记日志")
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("pairing.json"))
        XCTAssertNil(store.load())
        let line = try XCTUnwrap(logs.lines.first, "损坏的文件必须留一行日志")
        XCTAssertTrue(line.contains("pairing.json unreadable"), line)
    }

    func test_update_modifies_in_place_and_skips_when_unpaired() throws {
        let store = PairingStore(root: dir)
        XCTAssertFalse(try store.update { $0.pairingId = "x" })
        try store.save(record())
        XCTAssertTrue(try store.update { $0.pairingId = "e2" })
        XCTAssertEqual(store.load(), record(pairingId: "e2"))
    }

    func test_pairing_fails_visibly_and_does_not_report_paired_when_persisting_fails() async throws {
        let store = PairingStore(root: dir)
        try blockPairingFile()
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingId: "e9")),
        ])
        var paired = 0
        let outcome = await makePairing(transport, store: store) { _, _ in paired += 1; return false }.pair(code: link)
        guard case .failed(let reason) = outcome else { return XCTFail("写盘失败应当配对失败，实际 \(outcome)") }
        XCTAssertTrue(reason.contains(L.s("pair_save_failed")), reason)
        XCTAssertEqual(paired, 0, "没落盘就不能触发 onPaired")
    }

    func test_accepted_path_also_fails_when_persisting_fails() async throws {
        let store = PairingStore(root: dir)
        try blockPairingFile()
        // 老桌面：pair.request 直接回 accepted（无 request_id），不走轮询。
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(capabilities: [PairVerdictLoop.statusCapability])),
            Methods.pairRequest: try .ok(PairAccepted(storageDeviceName: "Mac", pairingId: "e9")),
        ])
        var paired = 0
        let outcome = await makePairing(transport, store: store) { _, _ in paired += 1; return false }.pair(code: link)
        guard case .failed = outcome else { return XCTFail("实际 \(outcome)") }
        XCTAssertEqual(paired, 0)
    }

    /// #982：「这台电脑以前连过吗」必须在 onPaired 把它标成连过**之前**定。之前顺序反了，firstTime 恒为 false，
    /// 首次配对既进不了选相册、也进不了完成页（后台备份的选择因此不可达）。
    /// 反证：把 `known` 改回在 save 之后求值，本条红。
    func test_first_time_is_decided_before_onPaired_marks_the_desktop() async throws {
        let store = PairingStore(root: dir)
        var marked = Set<String>()
        var knownSeenByOnPaired: Bool?
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingId: "e9")),
        ])
        let pairing = makePairing(transport, store: store, onboarded: { marked.contains($0) }) { record, known in
            knownSeenByOnPaired = known
            marked.insert(record.daemonNodeId) // 最坏情形：onPaired 里就标记（#1019 之前的写法），firstTime 也必须先定
            return false
        }
        let outcome = await pairing.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true), "新电脑：onPaired 标记之后也必须报 firstTime")
        XCTAssertEqual(knownSeenByOnPaired, false)
    }

    func test_known_desktop_reports_not_first_time_and_tells_onPaired() async throws {
        let store = PairingStore(root: dir)
        var knownSeenByOnPaired: Bool?
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingId: "e9")),
        ])
        let outcome = await makePairing(transport, store: store, onboarded: { _ in true }) { _, known in knownSeenByOnPaired = known; return false }.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: false))
        XCTAssertEqual(knownSeenByOnPaired, true)
    }

    func test_member_fast_path_saves_name_and_pairing_id_when_hello_succeeds() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingId: "e9")),
        ])
        var paired: PairingRecord?
        let outcome = await makePairing(transport, store: store) { r, _ in paired = r; return false }.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true))
        XCTAssertEqual(store.load()?.pairingId, "e9")
        XCTAssertEqual(store.load()?.storageDeviceName, "Mac")
        XCTAssertEqual(paired?.pairingId, "e9")
    }

    // MARK: 换新电脑清旧的后台备份意图写失败（#1039，对位 Android）

    /// 偏好放在单独的目录里，改成只读（0o500：能读、建不出原子写的临时文件）——配对文件所在目录照常可写。
    private func readOnlyPrefs(requested: Bool) throws -> (AutoBackupPrefs, URL) {
        let prefsDir = dir.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        let prefs = AutoBackupPrefs(directory: prefsDir)
        try prefs.set(requested: requested, enabled: false) // 断开旧电脑后：停生产者、留意图（MOB-93）
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: prefsDir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefsDir.path) }
        XCTAssertEqual(prefs.requested(), requested, "前提：只读目录下读仍然有效")
        return (prefs, prefsDir)
    }

    /// 新电脑清意图没写下来：不抛、不拦配对（配对照常落盘、报首次），结局带上「要提示」；日志留一行；盘上仍是旧意图。
    /// 反证：让 `applyAutoBackupOnPairing` 在失败时返回 false（回到只记日志），`settingSaveFailed` 断言红。
    func test_new_desktop_intent_clear_failure_does_not_block_pairing_and_asks_for_a_notice() async throws {
        let (prefs, _) = try readOnlyPrefs(requested: true)
        let logs = LogSink()
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingId: "e9")),
        ])
        let outcome = await makePairing(transport, store: store, onboarded: { _ in false }) { _, known in
            applyAutoBackupOnPairing(prefs, knownDesktop: known, logger: logs)
        }.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true, settingSaveFailed: true))
        XCTAssertEqual(store.load()?.pairingId, "e9", "配对照常落盘")
        XCTAssertTrue(prefs.requested(), "没写下来：旧意图还在盘上——要靠完成页再写一次")
        let line = try XCTUnwrap(logs.lines.first)
        XCTAssertTrue(line.contains("apply on pairing failed"), line)
    }

    /// 连回以前连过的电脑、按意图恢复失败：只记日志，不提示（Android `settingsWriter.quiet`）——意图还在盘上。
    /// 反证：把 `applyAutoBackupOnPairing` 的 `return !knownDesktop` 改成 `return true`，本条红。
    func test_known_desktop_restore_failure_is_logged_only() throws {
        let (prefs, _) = try readOnlyPrefs(requested: true)
        let logs = LogSink()
        XCTAssertFalse(applyAutoBackupOnPairing(prefs, knownDesktop: true, logger: logs))
        XCTAssertFalse(prefs.enabled(), "没恢复成")
        XCTAssertTrue(logs.lines.first?.contains("apply on pairing failed") == true, "\(logs.lines)")
    }

    func test_new_desktop_intent_clear_success_needs_no_notice() throws {
        let prefs = AutoBackupPrefs(directory: dir)
        try prefs.set(requested: true, enabled: false)
        XCTAssertFalse(applyAutoBackupOnPairing(prefs, knownDesktop: false, logger: LogSink()))
        XCTAssertFalse(prefs.requested())
    }

    // MARK: 快路径 hello 失败（#970）

    func test_member_fast_path_hello_failure_falls_back_to_pairing_without_saving_empty_pairing_id() async throws {
        let store = PairingStore(root: dir)
        // hello 连不上（超时 / 异常）：落回正常配对（它自己的 hello 同样连不上 → unreachable），不能存空记录。
        let transport = ScriptedTransport([Methods.hello: .fail])
        var paired = 0
        let outcome = await makePairing(transport, store: store) { _, _ in paired += 1; return false }.pair(code: link)
        guard case .failed = outcome else { return XCTFail("实际 \(outcome)") }
        XCTAssertNil(store.load(), "hello 失败不许存空 pairingId / 空电脑名")
        XCTAssertEqual(paired, 0)
        XCTAssertEqual(transport.calls, [Methods.hello, Methods.hello],
                       "第二次 hello 来自正常配对流程——证明确实落回了配对")
    }

    /// #1052 E2 三种情况（成员见 test_member_fast_path_saves_name_and_pairing_id_when_hello_succeeds）。
    /// 非成员：未配对的电脑 hello 只回能力握手，不带 pairing_id → 走正常配对，且绝不再调 backup.begin。
    func test_non_member_hello_without_pairing_id_goes_through_normal_pairing() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(capabilities: [PairVerdictLoop.statusCapability], deviceName: "Mac")),
            Methods.pairRequest: try .ok(PairAccepted(storageDeviceName: "Mac", pairingId: "e5")),
        ])
        let outcome = await makePairing(transport, store: store).pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true))
        XCTAssertEqual(transport.calls, [Methods.hello, Methods.hello, Methods.pairRequest], "第一次 hello 判成员未过，第二次来自正常配对")
        XCTAssertFalse(transport.calls.contains(Methods.backupBegin), "成员探针不得再用 backup.begin")
        XCTAssertEqual(store.load()?.pairingId, "e5")
    }

    /// 空串 pairingId 也不算成员。
    func test_empty_pairing_id_is_not_member() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([Methods.hello: try .ok(Hello(deviceName: "Mac", pairingId: ""))])
        _ = await makePairing(transport, store: store).pair(code: link)
        XCTAssertNil(store.load(), "空 pairingId 不许当成员存盘")
        XCTAssertEqual(transport.calls.first, Methods.hello)
        XCTAssertGreaterThan(transport.calls.count, 1, "必须落回正常配对")
    }

    /// 未配对 / 配对记录已被电脑删除：桌面对这样的设备连 hello 都拒（not_paired）→ 落回正常配对。
    func test_not_paired_hello_denied_falls_back_to_pairing_and_never_calls_backup_begin() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: .resp(Resp(ok: false, error: RespError(code: Codes.notAuthorized, reason: "not_paired"))),
        ])
        let outcome = await makePairing(transport, store: store).pair(code: link)
        XCTAssertNil(store.load())
        guard case .failed = outcome else { return XCTFail("实际 \(outcome)") }
        XCTAssertFalse(transport.calls.contains(Methods.backupBegin))
        XCTAssertEqual(transport.calls.prefix(2), [Methods.hello, Methods.hello])
    }

    /// #1117：协议 v3 起旧配对作废；`pairing.json` 还是 `pairingEpoch` 旧键 → 按未配对处理（不迁移）。
    func test_legacy_pairing_json_with_epoch_key_is_treated_as_not_paired() throws {
        let legacy = #"{"daemonNodeId":"n","peerToken":"t","storageDeviceName":"Mac","pairedAt":1,"pairingEpoch":"e1","lost":false}"#
        try legacy.write(to: dir.appendingPathComponent("pairing.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(PairingStore(root: dir, log: { _ in }).load())
    }

    func test_member_fast_path_rejected_hello_also_falls_back() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: .resp(Resp(ok: false, error: RespError(code: "x", reason: "from_the_future"))),
        ])
        _ = await makePairing(transport, store: store).pair(code: link)
        XCTAssertNil(store.load())
    }

    // MARK: 主动断开（#956 关闭裁决：尽力通知一次，之后什么都不做）

    /// 电脑不可达：只试一次，配对照样清；清完之后存储根里没有任何文件还带着这台电脑的 peerToken——
    /// 回前台 / 网络恢复 / 重启时就没有任何东西能拿来再连它。
    /// 反证：恢复旧的发件箱（断开时把 peerToken 落进 pending_unpair.json）→ 最后一条红；把清理挪进成功分支 → 第二条红。
    func test_disconnect_with_an_unreachable_desktop_tries_once_and_leaves_no_credential_behind() async throws {
        let token = "PEER-TOKEN-SECRET"
        let store = PairingStore(root: dir)
        try store.save(PairingRecord(daemonNodeId: "d", peerToken: token, storageDeviceName: "Mac", pairedAt: 1, pairingId: "e1"))
        let transport = ScriptedTransport([:]) // device.unpair → 连不上
        let root: URL = dir
        let pairing = makeDisconnecting(transport, store: store, onDisconnect: {
            try? applyDisconnectManifest(root: root, runtime: NoopDisconnectRuntime())
        })
        await pairing.disconnect()
        XCTAssertEqual(transport.calls, [Methods.deviceUnpair])
        XCTAssertNil(store.load(), "电脑不可达也必须清掉配对")
        let leftovers = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains(token) == true }
        XCTAssertEqual(leftovers.map(\.lastPathComponent), [], "断开后盘上不许再有这台电脑的 peerToken")
    }

    /// 配对已失效（lost）：电脑本就不认这台手机，不发，直接清。
    func test_disconnect_of_a_lost_pairing_sends_nothing_and_still_clears() async throws {
        let store = PairingStore(root: dir)
        try store.save(record(lost: true))
        let transport = ScriptedTransport([:])
        var cleared = false
        await makeDisconnecting(transport, store: store, onDisconnect: { cleared = true }).disconnect()
        XCTAssertEqual(transport.calls, [])
        XCTAssertTrue(cleared)
    }

    // MARK: 引擎接线（#967 / #966）

    /// 引擎一侧看到 hello 宣布的代号与本地不一致 = pairing_mismatch：按被拒处理（记 PairingLoss → 被拒即清理），不再把新代号写回记录。
    /// 反证：改回「把宣布的代号写进 pairing.json」，记录被改写、PairingLoss 不触发，两条断言红。
    func test_advertised_pairing_id_mismatch_is_treated_as_a_rejection_not_adopted() throws {
        let store = PairingStore(root: dir)
        try store.save(record(pairingId: "e1"))
        let loss = PairingLoss()
        let fired = Counter()
        loss.setOnLost { _ in fired.bump() }
        FlowWiring.pairingIdAdvertised(loss: loss, currentPairingId: { store.load()?.pairingId })("e2")
        XCTAssertEqual(fired.value, 1)
        XCTAssertTrue(loss.isLost(pairingId: "e1"))
        XCTAssertEqual(store.load(), record(pairingId: "e1"), "不采纳电脑宣布的新代号")
    }

    func test_audit_after_cycle_flushes_the_outbox_to_the_desktop_and_clears_acknowledged_events() async throws {
        let orders = try SQLiteOrderStore(directory: dir, logger: LogSink())
        try orders.appendAudit(AuditRecord(eventId: "a1", kind: "flow.round.finished", roundId: nil, occurredAtMs: 1, payload: [:]))
        let desktop = AuditDesktop()
        let store = PairingStore(root: dir)
        try store.save(record())
        let dispatcher = AuditOutboxDispatcher(store: orders, desktop: FlowWiring.auditDesktop(store: store, desktop: desktop),
                                               acknowledge: { ids in try? orders.acknowledgeAudit(ids) })
        await FlowWiring.afterCycle(dispatcher: dispatcher)()
        try await waitUntil { desktop.submitted.contains("a1") }
        try await waitUntil { ((try? orders.pendingAuditAfter(0, limit: 10)) ?? []).isEmpty }
    }

    func test_audit_is_not_sent_when_not_paired() async throws {
        let orders = try SQLiteOrderStore(directory: dir, logger: LogSink())
        try orders.appendAudit(AuditRecord(eventId: "a1", kind: "flow.round.finished", roundId: nil, occurredAtMs: 1, payload: [:]))
        let desktop = AuditDesktop()
        let dispatcher = AuditOutboxDispatcher(store: orders, desktop: FlowWiring.auditDesktop(store: PairingStore(root: dir), desktop: desktop),
                                               acknowledge: { _ in XCTFail("未配对不该确认任何事件") })
        await dispatcher.flush()
        XCTAssertTrue(desktop.submitted.isEmpty)
        XCTAssertEqual(try orders.pendingAuditAfter(0, limit: 10).count, 1, "outbox 原样留着")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not reached")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private final class AuditDesktop: FlowDesktop, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var submitted: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    func auditSubmit(_ events: [FlowAuditEvent]) async throws -> FlowAuditAccepted {
        lock.lock(); ids += events.map(\.eventId); lock.unlock()
        return FlowAuditAccepted(eventIds: events.map(\.eventId))
    }
    func hello() async throws -> Hello { fatalError("unused") }
    func offer(_ request: FlowFetchRequest) async throws -> FlowStatusReply { fatalError("unused") }
    func status(_ tuple: FlowTupleRef) async throws -> FlowStatusReply { fatalError("unused") }
    func suspendFetch(_ tuple: FlowTupleRef) async throws { fatalError("unused") }
    func cancelTuple(_ tuple: FlowTupleRef) async throws { fatalError("unused") }
    func presence(_ query: BackupPresenceQuery) async throws -> BackupMissing { fatalError("unused") }
}

private struct NoopDisconnectRuntime: DisconnectRuntime {
    func stopFlowRuntime() {}
    func cancelScheduledWakes() {}
    func stopMediaChangeObserver() {}
    func clearThumbnailMemoryCache() {}
}
