import XCTest
import Photos
import SQLite3
@testable import PPassMedia

/// 收件箱（取新系统，refs #958）。设计：P-Pass-iOS-取新系统-设计.md §3；测试清单编号见每条注释（§6-N）。
final class InboxTests: XCTestCase {
    private var path: String!
    private var logs: [String] = []

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("backup-orders.db").path
        logs = []
    }

    private func open(_ history: FakeChangeHistory) throws -> Inbox {
        try Inbox(path: path, history: history, log: { [weak self] in self?.logs.append($0) })
    }

    private func ids(_ entries: [InboxEntry]) -> [String] { entries.map(\.assetId) }

    /// 首次初始化（§3.1 初始化时机 / §6-7 的起点）：没有令牌时取当前令牌、返回当前最大序号（空表 0）；
    /// 此前的照片不进箱（它们走 SCOPE_ADDED 对账）。
    func testFirstPositionTakesTheCurrentTokenAndStartsAtZero() throws {
        let history = FakeChangeHistory()
        history.append(inserted: ["old-1", "old-2"])
        let inbox = try open(history)

        XCTAssertEqual(try inbox.currentPosition(), 0)
        XCTAssertEqual(try inbox.entries(after: 0, limit: 10), [], "初始化前已有的照片不进箱")

        history.append(inserted: ["new"])
        XCTAssertEqual(ids(try inbox.entries(after: 0, limit: 10)), ["new"])
    }

    /// §6-1（逐张推进）：一条变更新增 6 张，每张一个自己的序号，按 id 排序；从任意一张的序号往后取，只拿到它之后的。
    func testOneChangeWithSixPhotosGivesEachItsOwnSeq() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["f", "b", "e", "a", "d", "c"])

        let all = try inbox.entries(after: 0, limit: 10)
        XCTAssertEqual(ids(all), ["a", "b", "c", "d", "e", "f"], "同一条变更内按 id 排序")
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4, 5, 6], "每张一个序号——不再整批共用一个令牌")
        var delivered: [String] = []
        var g: Int64 = 0
        while let next = try inbox.entries(after: g, limit: 1).first {
            delivered.append(next.assetId)
            g = next.seq
        }
        XCTAssertEqual(delivered, ["a", "b", "c", "d", "e", "f"], "逐张提交，6 张全部取到、每张恰好一次")
    }

    /// 进箱顺序：多条变更按变更先后，变更内按 id；只看 inserted（updated / deleted 不进箱）。
    func testIngestOrderFollowsChangesThenIds() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["z"])
        history.append(inserted: ["b", "a"], updated: ["z"])
        history.append(deleted: ["old"])
        history.append(inserted: ["c"])

        let all = try inbox.entries(after: 0, limit: 10)
        XCTAssertEqual(ids(all), ["z", "a", "b", "c"])
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(ids(try inbox.entries(after: 2, limit: 1)), ["b"], "seq > after，按 seq，最多 limit 条")
    }

    /// §6-4：进箱途中被杀——已提交的变更不重复进箱，未提交的下次继续进箱。
    func testKilledMidIngestResumesWithoutDuplicatesOrGaps() throws {
        let history = FakeChangeHistory()
        let first = try open(history)
        _ = try first.currentPosition()
        history.append(inserted: ["a1", "a2"])
        history.append(inserted: ["b1"])
        history.append(inserted: ["c1", "c2"])

        struct Killed: Error {}
        var committed = 0
        first.afterChangeCommitted = {
            committed += 1
            if committed == 2 { throw Killed() }
        }
        XCTAssertThrowsError(try first.entries(after: 0, limit: 10)) { XCTAssertTrue($0 is Killed) }

        let restarted = try open(history)
        let all = try restarted.entries(after: 0, limit: 10)
        XCTAssertEqual(ids(all), ["a1", "a2", "b1", "c1", "c2"], "前两条已提交、第三条续上，不重不漏")
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4, 5])
    }

    /// §6-8：序号不复用——`currentPosition()`（G 重置）清掉 `seq <= 当前最大序号` 的行之后，新进箱的序号仍然更大。
    func testSeqIsNeverReusedAfterCleanup() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["a", "b", "c"])
        XCTAssertEqual(try inbox.entries(after: 0, limit: 10).map(\.seq), [1, 2, 3])

        let g = try inbox.currentPosition()
        XCTAssertEqual(g, 3, "G 重置为当前最大序号")
        XCTAssertEqual(try rowCount(), 0, "seq <= G 的行在重置时清掉")
        XCTAssertEqual(try inbox.currentPosition(), 3, "空表也不回到 0：最大序号是 AUTOINCREMENT 的高水位")

        history.append(inserted: ["d"])
        let next = try inbox.entries(after: g, limit: 10)
        XCTAssertEqual(ids(next), ["d"])
        XCTAssertEqual(next.first?.seq, 4, "新照片不会拿到比 G 还小的号")

        let reopened = try open(history)
        history.append(inserted: ["e"])
        XCTAssertEqual(try reopened.entries(after: 4, limit: 10).map(\.seq), [5], "重开连接也不复用")
    }

    /// 取件时不清理：只有 currentPosition() 删行（计数翻页传进来的 after 不是 G，不能拿它删）。
    func testReadingNeverDeletesRows() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["a", "b", "c"])
        _ = try inbox.entries(after: 0, limit: 10)
        _ = try inbox.entries(after: 3, limit: 10)
        XCTAssertEqual(ids(try inbox.entries(after: 0, limit: 10)), ["a", "b", "c"])
    }

    /// §6-9（方案改定：不抛错、不动 G）：令牌失效时收件箱只把自己的令牌重置为当前令牌、打一行日志，然后照常返回；
    /// 已进箱的行照常往下取；失效期间没进箱的照片留给对账。
    func testExpiredTokenResetsOnlyTheInboxTokenAndKeepsServing() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["a", "b"])
        XCTAssertEqual(ids(try inbox.entries(after: 0, limit: 1)), ["a"], "已有一行在 G 之后，不需要进箱")
        XCTAssertEqual(ids(try inbox.entries(after: 0, limit: 10)), ["a", "b"])

        for reason in [ChangeHistoryError.tokenExpired, .detailsUnavailable, .undecodableToken] {
            history.append(inserted: ["lost-\(reason)"])
            history.failure = reason
            XCTAssertEqual(ids(try inbox.entries(after: 1, limit: 10)), ["b"], "不抛错；已进箱的照常往下取")
            history.failure = nil
            XCTAssertTrue(logs.last?.contains("inbox: change token expired; reset to current, gap left to reconcile") == true, "\(logs)")
        }

        history.append(inserted: ["after"])
        XCTAssertEqual(ids(try inbox.entries(after: 1, limit: 10)), ["b", "after"], "令牌已重置到当前：之后的新照片照常进箱，缺口里的不进")
    }

    /// 其他错误（例如授权被收回）原样上抛，令牌不动。
    func testOtherHistoryErrorsAreRethrownAndKeepTheToken() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["a"])
        history.failure = .other(code: 3311, domain: PHPhotosErrorDomain)
        XCTAssertThrowsError(try inbox.entries(after: 0, limit: 10)) {
            XCTAssertEqual($0 as? ChangeHistoryError, .other(code: 3311, domain: PHPhotosErrorDomain))
        }
        history.failure = nil
        XCTAssertEqual(ids(try inbox.entries(after: 0, limit: 10)), ["a"], "令牌没被重置，授权恢复后那张照样进箱")
    }

    /// §6-10：同一个 id 重复进箱（例如删除后恢复、id 不变）——收件箱照实记两行，判重交给引擎（已有 order 时跳过）。
    /// 同一条变更里重复的 id 只记一行。
    func testTheSameIdInTwoChangesIsRecordedTwiceAndOnceWithinAChange() throws {
        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["x", "x", "y"])
        history.append(deleted: ["x"])
        history.append(inserted: ["x"])
        let all = try inbox.entries(after: 0, limit: 10)
        XCTAssertEqual(ids(all), ["x", "y", "x"])
        XCTAssertEqual(all.map(\.seq), [1, 2, 3])
    }

    /// 令牌缺失但 G 已存在（例如收件箱表被外力清掉）：当作首次初始化，从当前令牌起步，不崩溃。
    func testMissingTokenOnReadStartsFromNow() throws {
        let history = FakeChangeHistory()
        history.append(inserted: ["before"])
        let inbox = try open(history)
        XCTAssertEqual(try inbox.entries(after: 7, limit: 10), [])
        history.append(inserted: ["after"])
        XCTAssertEqual(ids(try inbox.entries(after: 0, limit: 10)), ["after"])
    }

    /// 和账本共用一个文件：收件箱只建自己的两张表，不碰 `user_version`（账本靠它判断要不要删表重建）。
    func testSharesTheFileWithoutTouchingUserVersionOrForeignTables() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 7; CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let history = FakeChangeHistory()
        let inbox = try open(history)
        _ = try inbox.currentPosition()
        history.append(inserted: ["a"])
        _ = try inbox.entries(after: 0, limit: 10)

        XCTAssertEqual(try scalar("PRAGMA user_version"), 7)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM meta"), 0, "账本的 meta 表不碰")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('inbox', 'inbox_meta')"), 2)
    }

    /// G 的编码：seq 的 8 字节大端；解不出（长度不对）按 0 处理。
    func testPositionEncodingRoundTripsAndGarbageIsZero() {
        for seq: Int64 in [0, 1, 255, 256, 1 << 40] {
            XCTAssertEqual(Inbox.seq(fromPosition: Inbox.position(of: seq)), seq)
        }
        XCTAssertEqual(Inbox.position(of: 1).count, 8)
        XCTAssertEqual(Inbox.seq(fromPosition: Data("{\"epoch\":1}".utf8)), 0)
        XCTAssertEqual(Inbox.seq(fromPosition: Data()), 0)
    }

    // MARK: helpers

    private func scalar(_ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 2) }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { throw NSError(domain: "sqlite", code: 3) }
        return sqlite3_column_int64(st, 0)
    }

    private func rowCount() throws -> Int64 { try scalar("SELECT COUNT(*) FROM inbox") }
}
