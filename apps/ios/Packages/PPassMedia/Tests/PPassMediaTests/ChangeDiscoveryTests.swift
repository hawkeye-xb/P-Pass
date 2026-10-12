import XCTest
import Photos
@testable import PPassMedia

/// 内存里的变更历史。token 用 "t0"、"t1"……的 UTF-8 字节表示。
final class FakeChangeHistory: ChangeHistoryReading {
    var records: [ChangeRecord] = []
    var current = FakeChangeHistory.token(0)
    var failure: ChangeHistoryError?
    private(set) var calls: [String] = []

    static func token(_ n: Int) -> ChangeToken { ChangeToken(archived: Data("t\(n)".utf8)) }

    func currentToken() throws -> ChangeToken {
        calls.append("current")
        return current
    }

    func changes(since token: ChangeToken) throws -> [ChangeRecord] {
        calls.append("changes")
        if let failure { throw failure }
        guard let start = records.firstIndex(where: { $0.token == token }) else {
            return token == Self.token(0) ? records : []
        }
        return Array(records[(start + 1)...])
    }

    @discardableResult
    func append(inserted: [String] = [], updated: [String] = [], deleted: [String] = []) -> ChangeToken {
        let token = Self.token(records.count + 1)
        records.append(ChangeRecord(token: token, inserted: inserted, updated: updated, deleted: deleted))
        current = token
        return token
    }
}

/// IOS-09（#335）：G 的取法、推进、不倒退、3105 兜底。
final class ChangeDiscoveryTests: XCTestCase {
    private let t = FakeChangeHistory.token

    func testMissingWatermarkStartsAtCurrentToken() throws {
        let history = FakeChangeHistory()
        history.append(inserted: ["old"])

        XCTAssertEqual(try ChangeDiscovery(history: history).discover(since: nil), .start(at: t(1)),
                       "没有 G 时从此刻起步，此前的照片归对账扫描")
    }

    func testNewPhotoAppearsAndOnlyItAppears() throws {
        let history = FakeChangeHistory()
        let g = try history.currentToken()
        history.append(inserted: ["new"])
        history.append(updated: ["new"]) // 入库后系统分析产生的更新，不是新照片

        guard case .changes(let window) = try ChangeDiscovery(history: history).discover(since: g) else {
            return XCTFail("expected incremental changes")
        }
        XCTAssertEqual(window.newAssetIds, ["new"])
        XCTAssertEqual(window.advance { $0 == "new" }, t(2), "提交后 G 前移到窗口末尾")
        XCTAssertEqual(window.advance { _ in false }, g, "没提交 G 不动——读的时候不推进")
    }

    func testAdvanceStopsBeforeFirstUnsettledInsert() {
        let window = ChangeWindow(from: t(0), records: [
            ChangeRecord(token: t(1), inserted: ["a"]),
            ChangeRecord(token: t(2), inserted: ["b", "c"]),
            ChangeRecord(token: t(3), inserted: ["d"]),
        ])
        XCTAssertEqual(window.newAssetIds, ["a", "b", "c", "d"])
        XCTAssertEqual(window.advance { ["a"].contains($0) }, t(1))
        XCTAssertEqual(window.advance { ["a", "b"].contains($0) }, t(1), "同一次变更里 c 没了结，这次变更整体不能越过")
        XCTAssertEqual(window.advance { ["a", "b", "c"].contains($0) }, t(2))
        XCTAssertEqual(window.advance { ["b", "c", "d"].contains($0) }, t(0), "按顺序提交：a 卡住，后面的都不越过")
    }

    // MARK: 卡面验收 4：删除 / 修改事件不得让水位倒退

    func testDeletesAndUpdatesNeverMoveWatermarkBackward() {
        let window = ChangeWindow(from: t(5), records: [
            ChangeRecord(token: t(6), deleted: ["backed-up-long-ago"]),
            ChangeRecord(token: t(7), updated: ["edited", "favorited"]),
            ChangeRecord(token: t(8), inserted: ["x"], deleted: ["another-old-one"]),
        ])
        XCTAssertEqual(window.newAssetIds, ["x"])
        XCTAssertEqual(window.deletedAssetIds, ["backed-up-long-ago", "another-old-one"])
        XCTAssertEqual(window.advance { _ in false }, t(7), "只有删除/更新的变更不挡 G，G 只往后走")
        XCTAssertEqual(window.advance { _ in true }, t(8))
        for settled in [Set<String>(), ["x"]] {
            let reached = window.advance { settled.contains($0) }
            XCTAssertTrue(reached == window.from || window.records.contains { $0.token == reached },
                          "G 只能是起点或系统给出的某个后续 token，结构上不可能倒退")
        }
    }

    func testInsertedThenDeletedInsideWindowDoesNotBlock() {
        let window = ChangeWindow(from: t(0), records: [
            ChangeRecord(token: t(1), inserted: ["shot-and-deleted"]),
            ChangeRecord(token: t(2), deleted: ["shot-and-deleted"]),
            ChangeRecord(token: t(3), inserted: ["kept"]),
        ])
        XCTAssertEqual(window.newAssetIds, ["kept"])
        XCTAssertEqual(window.deletedAssetIds, [], "窗口内插入又删的不算「删了一张老照片」")
        XCTAssertEqual(window.advance { _ in false }, t(2), "拍了又删的不挡 G")
    }

    func testEmptyWindowKeepsWatermark() throws {
        let history = FakeChangeHistory()
        history.append(inserted: ["a"])
        guard case .changes(let window) = try ChangeDiscovery(history: history).discover(since: t(1)) else {
            return XCTFail("expected changes")
        }
        XCTAssertEqual(window.records, [])
        XCTAssertEqual(window.endToken, t(1))
        XCTAssertEqual(window.advance { _ in true }, t(1))
    }

    // MARK: 卡面验收 3：3105 兜底

    func testExpiredTokenRequiresRescanAndTakesRestartTokenAfterFailure() throws {
        for reason in [ChangeHistoryError.tokenExpired, .detailsUnavailable, .undecodableToken] {
            let history = FakeChangeHistory()
            history.append(inserted: ["a"])
            history.failure = reason

            XCTAssertEqual(try ChangeDiscovery(history: history).discover(since: t(0)), .rescan(reason: reason, restartAt: t(1)))
            XCTAssertEqual(history.calls, ["changes", "current"], "重启点在读历史失败之后、重扫之前取")
        }
    }

    func testOtherErrorsAreNotTurnedIntoRescan() {
        let history = FakeChangeHistory()
        history.failure = .other(code: 3311, domain: PHPhotosErrorDomain)

        XCTAssertThrowsError(try ChangeDiscovery(history: history).discover(since: t(0))) { error in
            XCTAssertEqual(error as? ChangeHistoryError, .other(code: 3311, domain: PHPhotosErrorDomain),
                           "授权被拒不是「token 过期」，不许悄悄重扫")
        }
    }

    func testPhotoKitErrorClassification() {
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: PHPhotosErrorDomain, code: 3105)), .tokenExpired)
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: PHPhotosErrorDomain, code: 3210)), .detailsUnavailable)
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: PHPhotosErrorDomain, code: 3311)),
                       .other(code: 3311, domain: PHPhotosErrorDomain))
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: NSCocoaErrorDomain, code: 3105)),
                       .other(code: 3105, domain: NSCocoaErrorDomain), "只认 PHPhotosErrorDomain 的 3105")
    }

    func testGarbageBytesAreUndecodable() {
        XCTAssertThrowsError(try PhotoKitChangeHistory().changes(since: ChangeToken(archived: Data("not a token".utf8)))) {
            XCTAssertEqual($0 as? ChangeHistoryError, .undecodableToken)
        }
    }

    /// 3105 之后的收敛**按内容哈希判定，不按计数**。
    /// 场景：已备份 A、B；token 过期期间 B 被删、C 被加进来。范围计数还是 2，看计数会以为「没有要做的」；
    /// 按哈希判重，A 回「已有」不重传，C 被传，B 的删除不影响任何东西。
    func testRescanAfterExpiryConvergesByContentHashNotByCount() throws {
        let lib = FakePhotoLibrary()
        for id in ["A", "C"] { lib.add(.init(id: id)) }
        lib.addCollection("recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary, assets: ["A", "C"])
        let contentHash = ["A": "hash-a", "B": "hash-b", "C": "hash-c"]
        var desktop: Set<String> = ["hash-a", "hash-b"]
        let countWhenBackedUp = 2

        let history = FakeChangeHistory()
        history.failure = .tokenExpired
        guard case .rescan(_, let restartAt) = try ChangeDiscovery(history: history).discover(since: t(0)) else {
            return XCTFail("expected rescan")
        }
        let store = ChangeTokenStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try store.save(restartAt) // 先落 G，再扫

        let inScope = AlbumScope(library: lib).assetIdentifiers(inAlbums: ["recents"])
        XCTAssertEqual(inScope.count, countWhenBackedUp, "计数没变——光看计数会判成「没有要做的」")
        var transferred: [String] = []
        for id in inScope.sorted() {
            let hash = try XCTUnwrap(contentHash[id])
            if desktop.contains(hash) { continue } // offer → 桌面回「已有」= 完成
            transferred.append(id)
            desktop.insert(hash)
        }
        XCTAssertEqual(transferred, ["C"], "A 按内容哈希判重不重传，C 被补上")
        XCTAssertEqual(try store.load(), restartAt)
    }

    // MARK: 落盘

    func testTokenStoreRoundTripAndAtomicReplace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChangeTokenStore(directory: dir)
        XCTAssertNil(try store.load())
        try store.save(t(1))
        try store.save(t(2))
        XCTAssertEqual(try ChangeTokenStore(directory: dir).load(), t(2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["photos.change-token"], "原子写不留临时文件")
    }

    func testCorruptedStoreLeadsToRescanNotSilentRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChangeTokenStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: store.fileURL)

        let loaded = try XCTUnwrap(try store.load(), "坏文件不能读成「没有 G」，否则会从此刻起步、漏掉中间的照片")
        XCTAssertThrowsError(try PhotoKitChangeHistory().changes(since: loaded)) {
            XCTAssertEqual($0 as? ChangeHistoryError, .undecodableToken)
        }
    }
}
