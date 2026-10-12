import XCTest
import Photos
import PPassMedia

/// IOS-09（#335）在模拟器真 PhotoKit 上的验收。
final class ChangeTokenIT: XCTestCase {
    private func storeDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("change-token-it-\(UUID().uuidString)")
    }

    /// 验收 1 + 2：token 归档 → 落盘 → 新实例读回 → 解档后仍能用于 fetchPersistentChanges；
    /// 新增一张照片 → 增量里只出现这一张 → 提交后 G 前移 → 再读一次是空窗口。
    func testTokenRoundTripThroughStoreAndNewPhotoAdvancesWatermark() throws {
        try IT.requireFullAccess()
        let history = PhotoKitChangeHistory()
        let discovery = ChangeDiscovery(history: history)
        let dir = storeDir()

        guard case .start(let g0) = try discovery.discover(since: nil) else { return XCTFail("expected start") }
        try ChangeTokenStore(directory: dir).save(g0)
        let reloaded = try XCTUnwrap(try ChangeTokenStore(directory: dir).load())
        XCTAssertEqual(reloaded, g0)
        let decoded = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: reloaded.archived))
        XCTAssertNoThrow(try PHPhotoLibrary.shared().fetchPersistentChanges(since: decoded), "读回的 token 直接喂给系统 API 能用")

        let newId = try IT.createPhoto(label: "watermark-\(IT.nonce)")

        guard case .changes(let window) = try discovery.discover(since: reloaded) else { return XCTFail("expected changes") }
        print("IT-WATERMARK records=\(window.records.count) inserted=\(window.records.map(\.insertedAssetIds)) updated=\(window.records.map(\.updatedAssetIds)) deleted=\(window.records.map(\.deletedAssetIds))")
        XCTAssertEqual(window.newAssetIds, [newId], "增量里出现且只出现新加的这一张")
        XCTAssertEqual(window.advance { _ in false }, reloaded, "没提交，G 不动")

        let g1 = window.advance { $0 == newId }
        XCTAssertNotEqual(g1, reloaded, "提交后水位前移")
        try ChangeTokenStore(directory: dir).save(g1)

        guard case .changes(let after) = try discovery.discover(since: try XCTUnwrap(try ChangeTokenStore(directory: dir).load())) else {
            return XCTFail("expected changes")
        }
        XCTAssertEqual(after.newAssetIds, [], "G 越过之后，这张不会再作为新照片出现")
        print("IT-WATERMARK after-advance records=\(after.records.count) new=\(after.newAssetIds)")
    }

    /// 验收 4 的真库侧：加进相册（一次集合变更，不改照片本身）不会让那张照片重新算作新照片，G 照样往后走。
    func testAlbumMembershipChangeIsNotANewPhoto() throws {
        try IT.requireFullAccess()
        let history = PhotoKitChangeHistory()
        let jpeg = try IT.asset(originalFilename: "a1.jpg")
        let g = try history.currentToken()

        _ = try IT.createAlbum(title: "PPIT-\(IT.nonce)-membership", assets: [jpeg])

        guard case .changes(let window) = try ChangeDiscovery(history: history).discover(since: g) else { return XCTFail("expected changes") }
        print("IT-MEMBERSHIP records=\(window.records.count) inserted=\(window.records.map(\.insertedAssetIds)) updated=\(window.records.map(\.updatedAssetIds))")
        XCTAssertEqual(window.newAssetIds, [], "老照片进相册不是新照片——范围变化由对账扫描负责，不归 G")
        XCTAssertEqual(window.advance { _ in false }, window.endToken, "没有新照片挡着，G 走到窗口末尾")
    }

    /// 验收 3（模拟方式）：真库造不出 3105，用存坏的 token 走同一条兜底路径——解不出 → rescan，
    /// restartAt 是真库此刻的 token，之后能正常增量。
    func testUndecodableStoredTokenFallsBackToRescanWithUsableRestartToken() throws {
        try IT.requireFullAccess()
        let dir = storeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ChangeTokenStore(directory: dir)
        try Data("corrupted".utf8).write(to: store.fileURL)

        let discovery = ChangeDiscovery(history: PhotoKitChangeHistory())
        guard case .rescan(let reason, let restartAt) = try discovery.discover(since: try store.load()) else {
            return XCTFail("expected rescan")
        }
        XCTAssertEqual(reason, .undecodableToken)
        try store.save(restartAt)
        let newId = try IT.createPhoto(label: "after-rescan-\(IT.nonce)")
        guard case .changes(let window) = try discovery.discover(since: try store.load()) else { return XCTFail("expected changes") }
        XCTAssertEqual(window.newAssetIds, [newId], "重扫后 G 从 restartAt 接着走，重扫期间及之后的新照片不丢")
    }
}
