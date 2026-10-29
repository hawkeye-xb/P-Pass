// #1263：时间档在真引擎上的效果。范围仍只是查询条件（#413 裁定 8）：键里带拍摄时刻，引擎经注入的 inScope 判断，
// 扫描 / 发现 / 已落库的行走同一个判断。
import XCTest
@testable import PPassCore

final class ScopeTimeEngineTests: XCTestCase {
    private let today: Int64 = 1_793_203_200_000

    /// 媒体源按 [since] 判断：相册 R 被选中，且拍摄时刻在时间档内。
    private func rig(since: Locked<BackupSince>) throws -> Rig {
        let rig = try Rig()
        rig.media.scopeRule.set { key in ScopeKey.inScope(key, selected: ["R"], since: since.get()) }
        return rig
    }

    private func key(_ capturedAtMs: Int64) -> String { ScopeKey.encode(albums: ["R"], capturedAtMs: capturedAtMs) }

    /// 默认「从今天起」：以前的照片不传，今天之后新增的传；改成「全部」走 SCOPE_ADDED 补扫，以前的照片补传。
    /// 反证：把 `ScopeKey.inTime` 恒返回 true，第一段就会传 1、2，红。
    func testFromTodaySkipsOlderPhotosAndAllBackfillsThem() async throws {
        let since = Locked(BackupSince.since(ms: today))
        let rig = try rig(since: since)
        rig.photo(1, generation: 1, bucket: key(today - 86_400_000))
        rig.photo(2, generation: 2, bucket: key(today - 1))
        rig.photo(3, generation: 3, bucket: key(today + 60_000))
        await rig.start()
        await rig.trigger(.scopeAdded)
        XCTAssertEqual(rig.delivery.deliveredIds, [3], "只传今天的")
        var pending = await rig.pending()
        XCTAssertEqual(pending, 0, "以前的照片不算待备份")

        rig.photo(4, generation: 4, bucket: key(today + 120_000))
        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.deliveredIds, [3, 4], "今天之后新增的照片照常传")

        since.set(.all)
        await rig.trigger(.scopeAdded)
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2, 3, 4], "改成全部：以前的照片补传")
        pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    /// 「全部 → 从今天起」：已经传完的留着不动；还没传的以前的照片不再传、从待办里消失；以后扩回来会自动回来。
    /// 反证：把引擎取件处的 `inScope(order.bucketId)` 去掉，第一段会把 1 传出去，红。
    func testNarrowingToTodayDropsUnsentOlderPhotosButKeepsConfirmed() async throws {
        let since = Locked(BackupSince.all)
        let rig = try rig(since: since)
        let done = rig.photo(1, generation: 1, bucket: key(today - 86_400_000))
        let waiting = rig.photo(2, generation: 2, bucket: key(today - 86_400_000))
        try rig.order(done, .confirmed)
        try rig.order(waiting, .pending)
        try rig.advanceG(2)
        await rig.start()

        since.set(.since(ms: today)) // 缩小：不触发 SCOPE_ADDED
        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.deliveredIds, [], "没传的以前的照片不再传")
        XCTAssertEqual(try rig.state(1), .confirmed, "已经传完的不删")
        XCTAssertEqual(try rig.state(2), .pending, "行还在，只是不在范围内")
        var pending = await rig.pending()
        XCTAssertEqual(pending, 0, "从待办里消失")

        since.set(.all)
        await rig.trigger(.scopeAdded)
        XCTAssertEqual(rig.delivery.deliveredIds, [2], "扩回来，自动回来")
        pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }
}
