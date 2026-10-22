import XCTest
import Photos
@testable import PPassMedia

/// #968 / #1016：源版本只随「实际备份的那份资源」的内容变，不随收藏、挪相册等元数据变；只用公开信息。
final class ContentVersionTests: XCTestCase {
    private func v(_ types: [PHAssetResourceType], adj: String? = nil, modified: Int64 = 1, media: PHAssetMediaType = .image) -> OriginalContent {
        originalContent(types: types, mediaType: media, adjustmentDigest: adj, modifiedAtMs: modified)
    }

    /// 反证：只用修改时间的口径下，收藏 / 挪相册推进修改时间，版本就变；这里不变。
    func testMetadataOnlyChangeKeepsTheVersion() {
        XCTAssertEqual(v([.photo], modified: 1_000).version, v([.photo], modified: 2_500).version)
        let edited = [PHAssetResourceType.photo, .adjustmentData, .fullSizePhoto]
        XCTAssertEqual(v(edited, adj: "aa", modified: 1_000).version, v(edited, adj: "aa", modified: 2_500).version,
                       "编辑过的照片：编辑记录没变，修改时间变了也不换版本")
        XCTAssertFalse(v([.photo]).degraded)
    }

    func testEditsChangeTheVersionAndRevertingGoesBack() {
        let original = v([.photo])
        let edited1 = v([.photo, .adjustmentData, .fullSizePhoto], adj: "aa")
        let edited2 = v([.photo, .adjustmentData, .fullSizePhoto], adj: "bb")
        let reverted = v([.photo])
        XCTAssertNotEqual(original.version, edited1.version)
        XCTAssertNotEqual(edited1.version, edited2.version, "再编辑：编辑记录换了")
        XCTAssertEqual(original.version, reverted.version)
    }

    /// 版本取的是 selectOriginalResource 选中的那份：编辑过的是渲染结果。
    func testVersionFollowsTheSelectedResource() {
        let c = v([.photo, .adjustmentData, .fullSizePhoto], adj: "aa")
        XCTAssertEqual(c.resourceIndex, 2)
        XCTAssertEqual(c.version, "5:adj:aa")
        XCTAssertEqual(v([.photo]).version, "1:original")
    }

    func testVideoUsesTheVideoResource() {
        XCTAssertEqual(v([.video], media: .video).version, "\(PHAssetResourceType.video.rawValue):original")
        XCTAssertEqual(v([.video, .adjustmentData, .fullSizeVideo], adj: "cc", media: .video).version, "6:adj:cc")
    }

    /// 编辑过、编辑记录读不到：明确降级（带修改时间，宁可多取不漏改），并标记 degraded 供调用方写日志。
    func testUnreadableEditRecordDegradesLoudly() {
        let edited = [PHAssetResourceType.photo, .adjustmentData, .fullSizePhoto]
        let a = v(edited, adj: nil, modified: 1_000)
        let b = v(edited, adj: nil, modified: 2_000)
        XCTAssertTrue(a.degraded)
        XCTAssertNotEqual(a.version, b.version, "降级版本带修改时间：改了就重取")
        XCTAssertFalse(v([.photo], adj: nil).degraded, "没编辑过不需要编辑记录")
    }

    func testNoOriginalResourceDegrades() {
        let c = v([.adjustmentData])
        XCTAssertNil(c.resourceIndex)
        XCTAssertTrue(c.degraded)
    }

    func testDigestIsStableAndContentSensitive() {
        XCTAssertEqual(adjustmentDigest(of: Data("a".utf8)), adjustmentDigest(of: Data("a".utf8)))
        XCTAssertNotEqual(adjustmentDigest(of: Data("a".utf8)), adjustmentDigest(of: Data("bb".utf8)))
        XCTAssertEqual(adjustmentDigest(of: Data()).count, 16)
    }
}
