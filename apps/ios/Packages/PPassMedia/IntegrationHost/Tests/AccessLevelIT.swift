import XCTest
import Photos
import PPassMedia

/// IOS-10（#336）在模拟器上的验收：scripts/test.sh 把宿主授权依次设成 full / limited / denied / 未决定，
/// 每档跑一次本测试，经 PPASS_MEDIA_EXPECTED_ACCESS 告诉它该读到哪一档。
///
/// 关键反证点：limited 档下，旧 API `authorizationStatus()` 返回 `.authorized`。如果实现误用旧 API，这里会读成 full 而变红。
final class AccessLevelIT: XCTestCase {
    func testLevelReadFromSystemMatchesWhatWasGranted() throws {
        guard let expectedRaw = ProcessInfo.processInfo.environment["PPASS_MEDIA_EXPECTED_ACCESS"], !expectedRaw.isEmpty else {
            throw XCTSkip("PPASS_MEDIA_EXPECTED_ACCESS not set——由 scripts/test.sh 的授权三档编排设置")
        }
        let expected = try XCTUnwrap(PhotoAccessLevel(rawValue: expectedRaw))
        let level = PhotoKitAuthorization().currentLevel()
        let presentation = PhotoAccessPresentation.of(level)
        let legacy = PHPhotoLibrary.authorizationStatus()
        let visible = PHAsset.fetchAssets(with: nil).count
        let extensionEnabled = BackgroundUploadGate.uploadJobExtensionEnabled()
        let gate = BackgroundUploadGate.mayCreateUploadJobs(level: level)
        print("IT-ACCESS expected=\(expected.rawValue) readWrite=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue) legacy=\(legacy.rawValue) level=\(level.rawValue) visibleAssets=\(visible) counts=\(presentation.showsBackupCounts) stamp=\(presentation.allowsAllBackedUpStamp) notice=\(presentation.notice?.titleKey ?? "-") action=\(presentation.notice?.action?.rawValue ?? "-") uploadJobExtensionEnabled=\(extensionEnabled.map(String.init(describing:)) ?? "n/a") mayCreateJobs=\(gate)")
        XCTAssertEqual(level, expected)
        XCTAssertEqual(presentation.showsBackupCounts, expected == .full)
        if expected == .limited {
            XCTAssertEqual(legacy, .authorized, "记录系统事实：limited 下旧 API 说的是 authorized——所以绝不能用它")
        }
        if extensionEnabled != true {
            XCTAssertFalse(gate, "开关没开，不许建 job")
        }
    }
}
