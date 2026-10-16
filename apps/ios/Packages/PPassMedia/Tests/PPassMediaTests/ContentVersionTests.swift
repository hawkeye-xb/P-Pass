import XCTest
import Photos
@testable import PPassMedia

/// #968：源版本只随「实际备份的那份资源」的内容变，不随收藏等元数据变。
final class ContentVersionTests: XCTestCase {
    private func v(_ types: [PHAssetResourceType], _ sizes: [Int64?], modified: Int64 = 1, media: PHAssetMediaType = .image) -> OriginalContent {
        originalContent(types: types, sizes: sizes, mediaType: media, modifiedAtMs: modified)
    }

    /// 反证：旧口径（modificationDate:0）下，收藏只推进修改时间，版本就变；新口径不变。
    func testMetadataOnlyChangeKeepsTheVersion() {
        let before = v([.photo], [5050], modified: 1_000)
        let afterFavorite = v([.photo], [5050], modified: 2_500)
        XCTAssertEqual(before.version, afterFavorite.version)
        XCTAssertFalse(before.degraded)
        XCTAssertNotEqual("1000:0", "2500:0", "旧口径会把它当新版本")
    }

    func testEditsChangeTheVersionAndRevertingGoesBack() {
        let original = v([.photo], [5050])
        let edited1 = v([.photo, .adjustmentData, .fullSizePhoto], [5050, 636, 3114])
        let edited2 = v([.photo, .adjustmentData, .fullSizePhoto], [5050, 636, 3344])
        let reverted = v([.photo], [5050])
        XCTAssertNotEqual(original.version, edited1.version)
        XCTAssertNotEqual(edited1.version, edited2.version)
        XCTAssertEqual(original.version, reverted.version)
    }

    /// 版本取的是 selectOriginalResource 选中的那份，不是第一份：编辑过的取渲染结果的大小。
    func testVersionFollowsTheSelectedResource() {
        let c = v([.photo, .adjustmentData, .fullSizePhoto], [5050, 636, 3114])
        XCTAssertEqual(c.resourceIndex, 2)
        XCTAssertEqual(c.size, 3114)
        XCTAssertEqual(c.version, "5:3114")
    }

    func testVideoUsesTheVideoResource() {
        let c = v([.video], [9_000_000], media: .video)
        XCTAssertEqual(c.version, "\(PHAssetResourceType.video.rawValue):9000000")
    }

    /// 取不到大小：明确降级（带修改时间，宁可多取不漏改），并标记 degraded 供调用方写日志；不退回 0。
    func testUnreadableSizeDegradesLoudly() {
        let a = v([.photo], [nil], modified: 1_000)
        let b = v([.photo], [nil], modified: 2_000)
        XCTAssertTrue(a.degraded)
        XCTAssertNil(a.size)
        XCTAssertNotEqual(a.version, b.version, "降级版本带修改时间：改了就重取")
        XCTAssertFalse(a.version.hasSuffix(":0"))
    }

    func testNoOriginalResourceDegrades() {
        let c = v([.adjustmentData], [10])
        XCTAssertNil(c.resourceIndex)
        XCTAssertTrue(c.degraded)
    }
}
