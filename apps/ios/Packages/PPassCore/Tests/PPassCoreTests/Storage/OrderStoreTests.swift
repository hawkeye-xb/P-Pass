// #338：OrderStore 契约（对位 Android `OrderStoreContract.kt` 逐条），对着真实 SQLite 文件跑；
// 另加 Android JVM 上跑不了、iOS 能真跑的几条：跨「重启」读回、事务中途失败整体回滚、坏库删库重建、字节序。
import Foundation
import XCTest
@testable import PPassCore

final class OrderStoreTests: XCTestCase {
    private var tmp: TempDir!
    private var clock: ManualClock!

    override func setUp() {
        tmp = TempDir(name)
        clock = ManualClock(1_000)
    }

    private func newStore(logger: CoreLogger = NoopLogger()) throws -> SQLiteOrderStore {
        try SQLiteOrderStore(directory: tmp.url, logger: logger, clock: clock.function)
    }

    private func newOrder(_ mediaId: String, _ state: OrderState = .transferring, hash: String?? = .none, version: String = "v1", bucket: String = "B7") -> NewOrder {
        let h: String? = hash ?? "h\(mediaId)"
        return NewOrder(mediaId: mediaId, sourceVersion: version, bucketId: bucket, contentHash: h, state: state, pairingEpoch: "e3")
    }

    private func pos(_ s: String) -> DiscoveryPosition { DiscoveryPosition(raw: Data(s.utf8)) }

    func testInsertAssignsIncreasingIdsAndCurrentIsNewestPerPhoto() throws {
        let store = try newStore()
        let a = try store.insert(newOrder("m10"))
        clock.now = 2_000
        let b = try store.insert(newOrder("m10", .pending, version: "v2"))
        XCTAssertGreaterThan(b.id, a.id)
        XCTAssertEqual(a.createdAtMs, 1_000)
        XCTAssertEqual(try store.currentForMedia("m10"), b)
        XCTAssertEqual(try store.currentInStates([.pending, .transferring]).map(\.id), [b.id])
        XCTAssertEqual(try store.currentInStates([.pending], afterId: b.id, limit: .max), [])
    }

    func testTransitionIsCompareAndSetAndWritesEverythingInOneStep() throws {
        let store = try newStore()
        try store.saveDiscoveryState(DiscoveryState(position: pos("g0"), libraryIdentity: "lib"))
        let o = try store.insert(newOrder("m1", hash: .some(nil)))
        XCTAssertFalse(try store.transition(o.id, expected: [.pending], to: .confirmed, countAttempt: false, contentHash: nil, advance: pos("g9"), scanTo: nil, audit: nil))
        XCTAssertEqual(try store.discoveryState()?.position, pos("g0"), "没转换就一条都不写")
        let audit = AuditRecord(eventId: "ev1", kind: "k", roundId: nil, occurredAtMs: 1, payload: [:])
        XCTAssertTrue(try store.transition(o.id, expected: [.transferring], to: .failed, countAttempt: true, contentHash: "abc", advance: pos("g9"), scanTo: "m42", audit: audit))
        let row = try XCTUnwrap(store.get(o.id))
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.attempts, 1)
        XCTAssertEqual(row.contentHash, "abc")
        XCTAssertEqual(try store.discoveryState(), DiscoveryState(position: pos("g9"), libraryIdentity: "lib"), "推进 G 不动库身份")
        XCTAssertEqual(try store.scanState().cursor, "m42")
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 10).map(\.record), [audit])
    }

    /// O-07 / E-01 的存储一半：结局、G、审计同一次写入——中途失败（这里用重复的 event_id 让审计插入失败）就**一条都不生效**。
    /// 反证：把 transition 的三步拆成三个事务，状态已经是 CONFIRMED 而 G 没动，红。
    func testAFailureInsideTheWriteRollsBackStateAndCursorTogether() throws {
        let store = try newStore()
        try store.saveDiscoveryState(DiscoveryState(position: pos("g0"), libraryIdentity: nil))
        try store.appendAudit(AuditRecord(eventId: "dup", kind: "k", roundId: nil, occurredAtMs: 1, payload: [:]))
        let o = try store.insert(newOrder("m1"))
        XCTAssertThrowsError(try store.transition(
            o.id, expected: [.transferring], to: .confirmed, countAttempt: false, contentHash: nil, advance: pos("g9"), scanTo: nil,
            audit: AuditRecord(eventId: "dup", kind: "k", roundId: nil, occurredAtMs: 2, payload: [:])
        ))
        XCTAssertEqual(try store.get(o.id)?.state, .transferring)
        XCTAssertEqual(try store.discoveryState()?.position, pos("g0"))
    }

    func testAuditOutboxPagesByIncreasingSeq() throws {
        let store = try newStore()
        for i in 1...5 { try store.appendAudit(AuditRecord(eventId: "ev\(i)", kind: "k", roundId: nil, occurredAtMs: Int64(i), payload: ["i": "\(i)"])) }
        let first = try store.pendingAuditAfter(0, limit: 2)
        XCTAssertEqual(first.map(\.record.eventId), ["ev1", "ev2"])
        XCTAssertLessThan(first[0].seq, first[1].seq)
        try store.acknowledgeAudit(["ev3"])
        let second = try store.pendingAuditAfter(first.last!.seq, limit: 2)
        XCTAssertEqual(second.map(\.record.eventId), ["ev4", "ev5"])
        XCTAssertEqual(try store.pendingAuditAfter(second.last!.seq, limit: 2), [])
        try store.appendAudit(AuditRecord(eventId: "ev6", kind: "k", roundId: nil, occurredAtMs: 6, payload: [:]))
        XCTAssertEqual(try store.pendingAuditAfter(second.last!.seq, limit: 2).map(\.record.eventId), ["ev6"])
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 10).map(\.record.eventId), ["ev1", "ev2", "ev4", "ev5", "ev6"])
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 1).first?.record.payload, ["i": "1"])
    }

    /// iOS 变体：G 是不透明位置，推进 = 覆盖写（单调由引擎保证，见 FlowEngine 的 O-12 测试）。库身份只由 saveDiscoveryState 改。
    func testDiscoveryPositionIsOverwrittenAndKeepsLibraryIdentity() throws {
        let store = try newStore()
        XCTAssertNil(try store.discoveryState())
        try store.advanceDiscovery(pos("a"))
        XCTAssertEqual(try store.discoveryState(), DiscoveryState(position: pos("a"), libraryIdentity: nil))
        try store.saveDiscoveryState(DiscoveryState(position: pos("b"), libraryIdentity: "lib-1"))
        try store.advanceDiscovery(pos("c"))
        XCTAssertEqual(try store.discoveryState(), DiscoveryState(position: pos("c"), libraryIdentity: "lib-1"))
    }

    func testScanCursorLifecycle() throws {
        let store = try newStore()
        XCTAssertEqual(try store.scanState(), ScanState(dirty: false, cursor: nil))
        try store.markScanDirty()
        try store.advanceScan("m5")
        try store.advanceScan("m3")
        XCTAssertEqual(try store.scanState(), ScanState(dirty: true, cursor: "m5"), "只往前走（字节序）")
        try store.markScanDirty()
        XCTAssertEqual(try store.scanState(), ScanState(dirty: true, cursor: nil))
        try store.finishScan()
        XCTAssertEqual(try store.scanState(), ScanState(dirty: false, cursor: nil))
    }

    func testCancelRemainingWritesSkipListAndSkipsOpenOrdersButNotSettledOnes() throws {
        let store = try newStore()
        let open = try store.insert(newOrder("m1"))
        try store.insert(newOrder("m2", .confirmed))
        try store.insert(newOrder("m4", .confirmed, version: "old"))
        let result = try store.cancelRemaining([
            SkipTarget(mediaId: "m1", sourceVersion: "v1", bucketId: "B7"),
            SkipTarget(mediaId: "m2", sourceVersion: "v1", bucketId: "B7"),
            SkipTarget(mediaId: "m3", sourceVersion: "v1", bucketId: "B8"),
            SkipTarget(mediaId: "m4", sourceVersion: "v1", bucketId: "B7"),
        ], audit: nil)
        XCTAssertEqual(result, SkipResult(written: 3, ordersSkipped: 1, untouched: 1))
        XCTAssertEqual(try store.get(open.id)?.state, .skippedByUser)
        XCTAssertTrue(try store.isSkipped("m1") && store.isSkipped("m3") && store.isSkipped("m4"))
        XCTAssertFalse(try store.isSkipped("m2"))
        XCTAssertEqual(try store.skipList().collect(), ["m1", "m3", "m4"])
        XCTAssertEqual(try store.countSkipped(bucketIds: ["B8"]), 1)
        XCTAssertEqual(try store.countCurrentByState(bucketIds: nil)[.skippedByUser], 3, "「已跳过」报名单")
    }

    /// X-02 的存储一半：取消剩余是一个事务——一个坏目标让整批回滚。反证：逐条提交，m1 已被跳过，红。
    func testCancelRemainingIsOneTransaction() throws {
        let store = try newStore()
        let open = try store.insert(newOrder("m1"))
        XCTAssertThrowsError(try store.cancelRemaining([
            SkipTarget(mediaId: "m1", sourceVersion: "v1", bucketId: "B7"),
            SkipTarget(mediaId: "", sourceVersion: "v1", bucketId: "B7"),
        ], audit: nil))
        XCTAssertEqual(try store.get(open.id)?.state, .transferring)
        XCTAssertFalse(try store.isSkipped("m1"))
    }

    func testRestoreEmptiesSkipListAndMarksScanDirty() throws {
        let store = try newStore()
        _ = try store.cancelRemaining([SkipTarget(mediaId: "m1", sourceVersion: "v1", bucketId: "B7"), SkipTarget(mediaId: "m2", sourceVersion: "v1", bucketId: "B7")], audit: nil)
        XCTAssertEqual(try store.restoreSkipped(audit: nil), 2)
        XCTAssertEqual(try store.countSkipped(bucketIds: nil), 0)
        XCTAssertEqual(try store.scanState(), ScanState(dirty: true, cursor: nil))
        XCTAssertNil(try store.countCurrentByState(bucketIds: nil)[.skippedByUser])
    }

    func testRetryFailedTurnsCurrentFailedRowsBackToPendingKeepingAttempts() throws {
        let store = try newStore()
        let o = try store.insert(newOrder("m1"))
        try store.transition(o.id, expected: [.transferring], to: .failed, countAttempt: true)
        XCTAssertEqual(try store.retryFailed(audit: nil), 1)
        XCTAssertEqual(try store.get(o.id)?.state, .pending)
        XCTAssertEqual(try store.get(o.id)?.attempts, 1)
    }

    /// P-01 的存储一半：换桌面清事实与游标，保留跳过名单，id 起点抬高。
    func testChangingDesktopsClearsFactsKeepsSkipListAndLiftsIdFloor() throws {
        let store = try newStore()
        XCTAssertFalse(try store.claimOwner("desk-a", idFloor: 100))
        let o = try store.insert(newOrder("m1"))
        XCTAssertGreaterThan(o.id, 100)
        _ = try store.cancelRemaining([SkipTarget(mediaId: "m2", sourceVersion: "v1", bucketId: "B7")], audit: nil)
        try store.saveDiscoveryState(DiscoveryState(position: pos("g"), libraryIdentity: "x"))
        XCTAssertFalse(try store.claimOwner("desk-a", idFloor: 5_000))
        XCTAssertTrue(try store.claimOwner("desk-b", idFloor: 5_000))
        XCTAssertNil(try store.get(o.id))
        XCTAssertNil(try store.discoveryState())
        XCTAssertTrue(try store.scanState().dirty)
        XCTAssertTrue(try store.isSkipped("m2"))
        XCTAssertGreaterThan(try store.insert(newOrder("m3")).id, 5_000)
    }

    func testUICountsReadCurrentRowsAndConfirmedPresent() throws {
        let store = try newStore()
        try store.insert(newOrder("m1", .confirmed))
        let gone = try store.insert(newOrder("m2", .confirmed))
        try store.setSourceMissing(gone.id, missing: true, audit: nil)
        try store.insert(newOrder("m3", .failed))
        XCTAssertEqual(try store.countCurrentByState(bucketIds: ["B7"])[.confirmed], 2)
        XCTAssertEqual(try store.countConfirmedPresent(bucketIds: ["B7"]), 1)
        XCTAssertEqual(try store.countConfirmedPresent(bucketIds: []), 0)
        XCTAssertEqual(try store.currentOrders().collect().map(\.mediaId), ["m1", "m2", "m3"])
        XCTAssertEqual(try store.confirmedWithHashAfter(0, limit: 10).count, 2)
    }

    /// #459：标记不动 updated_at，只对 CONFIRMED 生效，值没变返回 false。
    func testSourceMissingFlagOnlyOnConfirmedAndNeverMovesUpdatedAt() throws {
        let store = try newStore()
        let kept = try store.insert(newOrder("m1", .confirmed))
        let gone = try store.insert(newOrder("m2", .confirmed))
        let settled = try store.insert(newOrder("m3", .skippedSourceMissing))
        clock.now = 9_000
        XCTAssertTrue(try store.setSourceMissing(gone.id, missing: true, audit: nil))
        XCTAssertFalse(try store.setSourceMissing(gone.id, missing: true, audit: nil), "值没变")
        XCTAssertFalse(try store.setSourceMissing(settled.id, missing: true, audit: nil), "不是 CONFIRMED")
        XCTAssertEqual(try store.get(gone.id)?.updatedAtMs, 1_000)
        XCTAssertEqual(try store.lastConfirmedAtMs(), 1_000)
        XCTAssertEqual(try store.countSourceMissingSkipped(afterMs: 0, upToMs: .max), 1)
        XCTAssertTrue(try store.setSourceMissing(gone.id, missing: false, audit: nil))
        XCTAssertEqual(try store.countConfirmedPresent(bucketIds: ["B7"]), 2)
        XCTAssertEqual(try store.get(kept.id), kept)
    }

    func testAppendAuditOnceRecordsAKeyOnlyOnceEvenAfterAcknowledge() throws {
        let store = try newStore()
        let first = AuditRecord(eventId: "ev-1", kind: "reconciliation_resolved", roundId: nil, occurredAtMs: 1_000, payload: ["disposition": "UNRECOVERABLE"])
        XCTAssertTrue(try store.appendAuditOnce("unrecoverable:1:e1", first))
        XCTAssertFalse(try store.appendAuditOnce("unrecoverable:1:e1", AuditRecord(eventId: "ev-2", kind: "k", roundId: nil, occurredAtMs: 1, payload: [:])))
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 10).map(\.record.eventId), ["ev-1"])
        try store.acknowledgeAudit(["ev-1"])
        XCTAssertFalse(try store.appendAuditOnce("unrecoverable:1:e1", AuditRecord(eventId: "ev-3", kind: "k", roundId: nil, occurredAtMs: 1, payload: [:])))
        XCTAssertTrue(try store.appendAuditOnce("unrecoverable:1:e2", AuditRecord(eventId: "ev-4", kind: "k", roundId: nil, occurredAtMs: 1, payload: [:])))
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 10).map(\.record.eventId), ["ev-4"])
    }

    func testOpenRoundMarkerLivesUntilItsTerminalFact() throws {
        let store = try newStore()
        XCTAssertNil(try store.openRoundId())
        try store.openRound("round-1")
        XCTAssertEqual(try store.openRoundId(), "round-1")
        try store.appendAudit(AuditRecord(eventId: "ev-item", kind: "flow.item.confirmed", roundId: try store.openRoundId(), occurredAtMs: 1_500, payload: ["itemRef": "media:1"]))
        try store.closeRound(AuditRecord(eventId: "ev-round", kind: "flow.round.finished", roundId: "round-1", occurredAtMs: 2_000, payload: ["confirmed": "1"]))
        XCTAssertNil(try store.openRoundId())
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 10).map(\.record.eventId), ["ev-item", "ev-round"])
        try store.openRound("round-2")
        try store.closeRound(nil)
        XCTAssertNil(try store.openRoundId())
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 10).count, 2)
    }

    func testChangingDesktopsDropsTheOpenRound() throws {
        let store = try newStore()
        try store.claimOwner("desk-a", idFloor: 0)
        try store.openRound("round-1")
        XCTAssertTrue(try store.claimOwner("desk-b", idFloor: 0))
        XCTAssertNil(try store.openRoundId())
    }

    /// #935：配对（App 侧的唯一入口）必须走「换桌面」清理——否则新电脑继承旧电脑的「已确认」，首页显示 4/4 已备份而新电脑一张都没有。
    func testPairingANewDesktopDoesNotInheritTheOldDesktopsConfirmedCount() throws {
        let store = try newStore()
        try adoptDesktop(store, daemonNodeId: "node-a", nowMs: 1_000)
        _ = try store.insert(newOrder("m1", .confirmed))
        _ = try store.insert(newOrder("m2", .confirmed))
        XCTAssertEqual(try store.countConfirmedPresent(bucketIds: nil), 2)
        _ = try store.cancelRemaining([SkipTarget(mediaId: "m9", sourceVersion: "v1", bucketId: "B7")], audit: nil)

        XCTAssertTrue(try adoptDesktop(store, daemonNodeId: "node-b", nowMs: 1_800_000_000_000))
        XCTAssertEqual(try store.countConfirmedPresent(bucketIds: nil), 0, "换电脑后要重新备份")
        XCTAssertTrue(try store.isSkipped("m9"), "跳过名单是用户意图，保留")
        XCTAssertGreaterThan(try store.insert(newOrder("m1", .pending)).id, 1_800_000_000_000)
    }

    /// #935 守护：重新配对同一台电脑（断开 / 地址变了再扫码）不清账本，已备份的不重传。
    func testRepairingTheSameDesktopKeepsConfirmedOrders() throws {
        let store = try newStore()
        try adoptDesktop(store, daemonNodeId: "node-a", nowMs: 1_000)
        _ = try store.insert(newOrder("m1", .confirmed))
        XCTAssertFalse(try adoptDesktop(store, daemonNodeId: "node-a", nowMs: 5_000))
        XCTAssertEqual(try store.countConfirmedPresent(bucketIds: nil), 1)
        // 断开再连回 A、重启 App 后也一样
        store.close()
        let reopened = try newStore()
        XCTAssertFalse(try adoptDesktop(reopened, daemonNodeId: "node-a", nowMs: 9_000))
        XCTAssertEqual(try reopened.countConfirmedPresent(bucketIds: nil), 1)
    }

    // MARK: iOS 能真跑的额外几条

    /// 写入 → 关库（= 杀进程）→ 重开 → 读回：order、跳过名单、游标、未闭合轮、outbox 全在。
    func testEverythingSurvivesAReopen() throws {
        var store: SQLiteOrderStore? = try newStore()
        try store!.claimOwner("desk-a", idFloor: 10)
        let o = try store!.insert(newOrder("m1"))
        _ = try store!.cancelRemaining([SkipTarget(mediaId: "m9", sourceVersion: "v", bucketId: "B")], audit: nil)
        try store!.saveDiscoveryState(DiscoveryState(position: pos("g5"), libraryIdentity: "lib"))
        try store!.markScanDirty()
        try store!.advanceScan("m3")
        try store!.openRound("r1")
        try store!.appendAudit(AuditRecord(eventId: "e1", kind: "k", roundId: "r1", occurredAtMs: 1, payload: [:]))
        store!.close()
        store = nil

        let reopened = try newStore()
        XCTAssertEqual(try reopened.get(o.id)?.state, .transferring)
        XCTAssertTrue(try reopened.isSkipped("m9"))
        XCTAssertEqual(try reopened.discoveryState(), DiscoveryState(position: pos("g5"), libraryIdentity: "lib"))
        XCTAssertEqual(try reopened.scanState(), ScanState(dirty: true, cursor: "m3"))
        XCTAssertEqual(try reopened.openRoundId(), "r1")
        XCTAssertEqual(try reopened.pendingAuditAfter(0, limit: 5).map(\.record.eventId), ["e1"])
        XCTAssertFalse(try reopened.claimOwner("desk-a", idFloor: 0), "同一台桌面重开不清")
    }

    /// 坏库：对位 Android 默认 DatabaseErrorHandler——删库重建，空账本照常可用，并说实话（日志 + 标志位）。
    func testACorruptDatabaseIsRecreatedAndReported() throws {
        tmp.write(SQLiteOrderStore.fileName, String(repeating: "garbage not a sqlite file ", count: 200))
        let logger = RecordingLogger()
        let store = try newStore(logger: logger)
        XCTAssertTrue(store.recoveredFromCorruption)
        XCTAssertTrue(logger.contains("is corrupt"), "\(logger.lines)")
        XCTAssertEqual(try store.currentOrders().collect(), [])
        let o = try store.insert(newOrder("m1"))
        XCTAssertEqual(try store.get(o.id)?.mediaId, "m1")
    }

    /// 两路归并的前提：SQLite 的 ORDER BY media_id 与 [MediaOrder.precedes] 是同一个顺序（UTF-8 字节序），
    /// 选的 id 里有 Swift `String <` 会给出不同顺序的组合（预组合 é 与 e + 组合重音）。
    func testSQLiteOrderMatchesMediaOrder() throws {
        let store = try newStore()
        let ids = ["b", "B", "a/L0/001", "a/L0/010", "Z", "\u{00E9}", "e\u{0301}", "10", "9", "f"]
        for id in ids { try store.insert(newOrder(id)) }
        let fromSQLite = try store.currentOrders().collect().map(\.mediaId)
        XCTAssertEqual(fromSQLite.map { Array($0.utf8) }, ids.sorted(by: MediaOrder.precedes).map { Array($0.utf8) })
        XCTAssertEqual(fromSQLite.count, ids.count, "预组合与分解形式在 SQLite 里是两个不同的 id")
        XCTAssertTrue("\u{00E9}" == "e\u{0301}", "Swift 认为它们相等——所以归并绝不能用 String ==/< 比媒体 id")
    }

    /// 分页：超过一页（256）也一张不漏、按序。
    func testPagedReadsCrossPageBoundaries() throws {
        let store = try newStore()
        let ids = (0..<600).map { String(format: "m%04d", $0) }
        for id in ids.shuffled() { try store.insert(newOrder(id)) }
        XCTAssertEqual(try store.currentOrders().collect().map(\.mediaId), ids)
        _ = try store.cancelRemaining(ids.map { SkipTarget(mediaId: $0, sourceVersion: "v9", bucketId: "B") }, audit: nil)
        XCTAssertEqual(try store.skipList().collect(), ids)
    }
}
