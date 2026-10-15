import XCTest
import Photos
import PPassMedia

/// 收件箱（refs #958）在模拟器真 PhotoKit 上的验收：令牌存取、新照片进箱、坏令牌的处理。
final class ChangeTokenIT: XCTestCase {
    /// 令牌落进 `inbox_meta` → 新连接读回后仍能用于 `fetchPersistentChanges`：新增一张照片 → 进箱且只进这一张 →
    /// 从它的序号往后再取是空的；重开连接后再加一张，接着进箱、序号更大。
    func testTokenRoundTripThroughTheInboxAndNewPhotoIsIngestedOnce() throws {
        try IT.requireFullAccess()
        let path = InboxIT.dbPath()
        let inbox = try Inbox(path: path, history: PhotoKitChangeHistory())
        let g = try inbox.currentPosition()
        XCTAssertEqual(g, 0)

        let newId = try IT.createPhoto(label: "inbox-\(IT.nonce)")
        let first = try inbox.entries(after: g, limit: 50)
        print("IT-INBOX first=\(first.map { "\($0.seq):\(IT.filename(of: $0.assetId))" })")
        XCTAssertEqual(first.map(\.assetId), [newId], "收件箱里出现且只出现新加的这一张")
        let seq = try XCTUnwrap(first.first?.seq)
        XCTAssertEqual(try inbox.entries(after: seq, limit: 50), [], "G 越过之后，这张不会再出现")

        let reopened = try Inbox(path: path, history: PhotoKitChangeHistory())
        let second = try IT.createPhoto(label: "inbox-2-\(IT.nonce)")
        let next = try reopened.entries(after: seq, limit: 50)
        XCTAssertEqual(next.map(\.assetId), [second], "存下的令牌读回后照常可用")
        XCTAssertGreaterThan(try XCTUnwrap(next.first?.seq), seq)
    }

    /// 老照片加进相册（一次集合变更，不改照片本身）不进箱：范围变化由对账扫描负责，不归 G。
    func testAlbumMembershipChangeIsNotIngested() throws {
        try IT.requireFullAccess()
        let inbox = try Inbox(path: InboxIT.dbPath(), history: PhotoKitChangeHistory())
        let g = try inbox.currentPosition()
        let jpeg = try IT.asset(originalFilename: "a1.jpg")

        _ = try IT.createAlbum(title: "PPIT-\(IT.nonce)-membership", assets: [jpeg])

        XCTAssertEqual(try inbox.entries(after: g, limit: 50), [], "老照片进相册不是新照片")
    }

    /// 存坏的令牌（真库上造不出 3105 时的同一条路）：不抛错、令牌重置为当前、打日志；之后的新照片照常进箱。
    func testUndecodableStoredTokenResetsToCurrentAndKeepsIngesting() throws {
        try IT.requireFullAccess()
        let path = InboxIT.dbPath()
        let logs = LogBox()
        let inbox = try Inbox(path: path, history: PhotoKitChangeHistory(), log: logs.append)
        try InboxIT.plantToken(Data("corrupted".utf8), at: path)

        XCTAssertEqual(try inbox.entries(after: 0, limit: 50), [])
        XCTAssertTrue(logs.all.contains { $0.contains("inbox: change token expired; reset to current") }, "\(logs.all)")

        let newId = try IT.createPhoto(label: "after-reset-\(IT.nonce)")
        XCTAssertEqual(try inbox.entries(after: 0, limit: 50).map(\.assetId), [newId], "重置后从当前令牌接着进箱，新照片不丢")
    }
}
