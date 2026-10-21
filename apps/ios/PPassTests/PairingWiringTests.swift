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

    private func record(epoch: String = "e1", lost: Bool = false) -> PairingRecord {
        PairingRecord(daemonNodeId: "d", peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingEpoch: epoch, lost: lost)
    }

    private func makePairing(_ transport: ScriptedTransport, store: PairingStore,
                             onboarded: @escaping (String) -> Bool = { _ in false },
                             onPaired: @escaping (PairingRecord, Bool) -> Void = { _, _ in }) -> LivePairing {
        LivePairing(transportFor: { _ in transport }, store: store, onboarded: onboarded, onPaired: onPaired,
                    onDisconnect: {}, pending: PendingUnpairStore(directory: dir, logger: LogSink()),
                    flusher: PendingUnpairFlusher(store: PendingUnpairStore(directory: dir, logger: LogSink()), now: { 0 }, logger: LogSink()) { _ in ScriptedTransport([:]) })
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
        XCTAssertFalse(try store.update { $0.pairingEpoch = "x" })
        try store.save(record())
        XCTAssertTrue(try store.update { $0.pairingEpoch = "e2" })
        XCTAssertEqual(store.load(), record(epoch: "e2"))
    }

    func test_pairing_fails_visibly_and_does_not_report_paired_when_persisting_fails() async throws {
        let store = PairingStore(root: dir)
        try blockPairingFile()
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingEpoch: "e9")),
        ])
        var paired = 0
        let outcome = await makePairing(transport, store: store) { _, _ in paired += 1 }.pair(code: link)
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
            Methods.pairRequest: try .ok(PairAccepted(storageDeviceName: "Mac", pairingEpoch: "e9")),
        ])
        var paired = 0
        let outcome = await makePairing(transport, store: store) { _, _ in paired += 1 }.pair(code: link)
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
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingEpoch: "e9")),
        ])
        let pairing = makePairing(transport, store: store, onboarded: { marked.contains($0) }) { record, known in
            knownSeenByOnPaired = known
            marked.insert(record.daemonNodeId) // 最坏情形：onPaired 里就标记（#1019 之前的写法），firstTime 也必须先定
        }
        let outcome = await pairing.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true), "新电脑：onPaired 标记之后也必须报 firstTime")
        XCTAssertEqual(knownSeenByOnPaired, false)
    }

    func test_known_desktop_reports_not_first_time_and_tells_onPaired() async throws {
        let store = PairingStore(root: dir)
        var knownSeenByOnPaired: Bool?
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingEpoch: "e9")),
        ])
        let outcome = await makePairing(transport, store: store, onboarded: { _ in true }) { _, known in knownSeenByOnPaired = known }.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: false))
        XCTAssertEqual(knownSeenByOnPaired, true)
    }

    func test_member_fast_path_saves_name_and_epoch_when_hello_succeeds() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(deviceName: "Mac", pairingEpoch: "e9")),
        ])
        var paired: PairingRecord?
        let outcome = await makePairing(transport, store: store) { r, _ in paired = r }.pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true))
        XCTAssertEqual(store.load()?.pairingEpoch, "e9")
        XCTAssertEqual(store.load()?.storageDeviceName, "Mac")
        XCTAssertEqual(paired?.pairingEpoch, "e9")
    }

    // MARK: 快路径 hello 失败（#970）

    func test_member_fast_path_hello_failure_falls_back_to_pairing_without_saving_empty_epoch() async throws {
        let store = PairingStore(root: dir)
        // hello 连不上（超时 / 异常）：落回正常配对（它自己的 hello 同样连不上 → unreachable），不能存空记录。
        let transport = ScriptedTransport([Methods.hello: .fail])
        var paired = 0
        let outcome = await makePairing(transport, store: store) { _, _ in paired += 1 }.pair(code: link)
        guard case .failed = outcome else { return XCTFail("实际 \(outcome)") }
        XCTAssertNil(store.load(), "hello 失败不许存空 epoch / 空电脑名")
        XCTAssertEqual(paired, 0)
        XCTAssertEqual(transport.calls, [Methods.hello, Methods.hello],
                       "第二次 hello 来自正常配对流程——证明确实落回了配对")
    }

    /// #1052 E2 三种情况（成员见 test_member_fast_path_saves_name_and_epoch_when_hello_succeeds）。
    /// 非成员：未配对的电脑 hello 只回能力握手，不带 pairing_epoch → 走正常配对，且绝不再调 backup.begin。
    func test_non_member_hello_without_epoch_goes_through_normal_pairing() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: try .ok(Hello(capabilities: [PairVerdictLoop.statusCapability], deviceName: "Mac")),
            Methods.pairRequest: try .ok(PairAccepted(storageDeviceName: "Mac", pairingEpoch: "e5")),
        ])
        let outcome = await makePairing(transport, store: store).pair(code: link)
        XCTAssertEqual(outcome, .joined(firstTime: true))
        XCTAssertEqual(transport.calls, [Methods.hello, Methods.hello, Methods.pairRequest], "第一次 hello 判成员未过，第二次来自正常配对")
        XCTAssertFalse(transport.calls.contains(Methods.backupBegin), "成员探针不得再用 backup.begin")
        XCTAssertEqual(store.load()?.pairingEpoch, "e5")
    }

    /// 空串 epoch 也不算成员。
    func test_empty_epoch_is_not_member() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([Methods.hello: try .ok(Hello(deviceName: "Mac", pairingEpoch: ""))])
        _ = await makePairing(transport, store: store).pair(code: link)
        XCTAssertNil(store.load(), "空 epoch 不许当成员存盘")
        XCTAssertEqual(transport.calls.first, Methods.hello)
        XCTAssertGreaterThan(transport.calls.count, 1, "必须落回正常配对")
    }

    /// 已撤销：桌面对已撤销设备连 hello 都拒（authz `revoked_gets_nothing_not_even_hello`）→ 落回正常配对。
    func test_revoked_hello_denied_falls_back_to_pairing_and_never_calls_backup_begin() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: .resp(Resp(ok: false, error: RespError(code: Codes.notAuthorized, reason: "revoked"))),
        ])
        let outcome = await makePairing(transport, store: store).pair(code: link)
        XCTAssertNil(store.load())
        guard case .failed = outcome else { return XCTFail("实际 \(outcome)") }
        XCTAssertFalse(transport.calls.contains(Methods.backupBegin))
        XCTAssertEqual(transport.calls.prefix(2), [Methods.hello, Methods.hello])
    }

    func test_member_fast_path_rejected_hello_also_falls_back() async throws {
        let store = PairingStore(root: dir)
        let transport = ScriptedTransport([
            Methods.hello: .resp(Resp(ok: false, error: RespError(code: "x", reason: "from_the_future"))),
        ])
        _ = await makePairing(transport, store: store).pair(code: link)
        XCTAssertNil(store.load())
    }

    // MARK: 空 epoch 修复（#970）

    func test_outcome_mapping_matches_android() {
        XCTAssertEqual(applyEpochRepairOutcome(.success("e2")), .repaired("e2"))
        XCTAssertEqual(applyEpochRepairOutcome(.success("")), .lost)
        XCTAssertEqual(applyEpochRepairOutcome(.success("  ")), .lost)
        XCTAssertEqual(applyEpochRepairOutcome(.success(nil)), .lost)
        XCTAssertEqual(applyEpochRepairOutcome(.failure(ScriptedTransport.Unreachable())), .lost)
        XCTAssertTrue(needsEpochRepair(""))
        XCTAssertFalse(needsEpochRepair("e1"))
    }

    func test_repair_writes_back_the_epoch_the_desktop_reports() async throws {
        let store = PairingStore(root: dir)
        try store.save(record(epoch: ""))
        let repairer = EpochRepairer(store: store, hello: { "e7" }, logger: LogSink())
        let result = await repairer.repairIfNeeded()
        XCTAssertEqual(result, .repaired("e7"))
        XCTAssertEqual(store.load()?.pairingEpoch, "e7")
        XCTAssertEqual(store.load()?.lost, false)
    }

    func test_repair_marks_lost_when_hello_fails_or_has_no_epoch() async throws {
        for hello: @Sendable () async throws -> String? in [{ throw ScriptedTransport.Unreachable() }, { nil }, { "" }] {
            let store = PairingStore(root: dir)
            try store.save(record(epoch: ""))
            let result = await EpochRepairer(store: store, hello: hello, logger: LogSink()).repairIfNeeded()
            XCTAssertEqual(result, .lost)
            XCTAssertEqual(store.load()?.lost, true)
        }
    }

    func test_repair_is_skipped_when_not_needed_and_tried_once_per_process() async throws {
        let store = PairingStore(root: dir)
        let counter = Counter()
        let repairer = EpochRepairer(store: store, hello: { counter.bump(); return "e7" }, logger: LogSink())
        let unpaired = await repairer.repairIfNeeded()
        XCTAssertNil(unpaired)
        try store.save(record(epoch: "e1"))
        let healthy = await repairer.repairIfNeeded()
        XCTAssertNil(healthy)
        XCTAssertEqual(counter.value, 0)

        try store.save(record(epoch: ""))
        _ = await repairer.repairIfNeeded()
        try store.save(record(epoch: ""))
        let again = await repairer.repairIfNeeded()
        XCTAssertNil(again, "本进程只试一次（对位 Android epochRepairAttempted）")
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: 引擎接线（#967 / #966）

    func test_advertised_epoch_is_persisted_and_the_rest_of_the_record_is_kept() throws {
        let store = PairingStore(root: dir)
        try store.save(record(epoch: "e1"))
        FlowWiring.epochAdvertised(store: store, logger: LogSink())("e2")
        XCTAssertEqual(store.load(), record(epoch: "e2"))
    }

    func test_advertised_epoch_persist_failure_is_logged() throws {
        let logs = LogSink()
        let store = PairingStore(root: dir)
        try store.save(record(epoch: "e1"))
        // 目录只读：文件能读、临时文件建不出来 → 原子写失败。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        FlowWiring.epochAdvertised(store: store, logger: logs)("e2")
        let line = try XCTUnwrap(logs.lines.first, "写盘失败必须留一行日志")
        XCTAssertTrue(line.contains("cannot persist new pairing epoch"), line)
        XCTAssertEqual(store.load()?.pairingEpoch, "e1", "旧记录原样")
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
