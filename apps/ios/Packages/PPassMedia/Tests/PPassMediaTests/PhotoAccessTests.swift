import XCTest
import Photos
@testable import PPassMedia

/// IOS-10（#336）：授权档位 → 首页表达；后台上传闸门。
final class PhotoAccessTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(PhotoAccessLevel(readWriteStatus: .authorized), .full)
        XCTAssertEqual(PhotoAccessLevel(readWriteStatus: .limited), .limited)
        XCTAssertEqual(PhotoAccessLevel(readWriteStatus: .denied), .denied)
        XCTAssertEqual(PhotoAccessLevel(readWriteStatus: .restricted), .restricted)
        XCTAssertEqual(PhotoAccessLevel(readWriteStatus: .notDetermined), .notDetermined)
        XCTAssertEqual(PhotoAccessLevel(readWriteStatus: PHAuthorizationStatus(rawValue: 99)!), .denied, "未知档位按拿不到处理")
    }

    // MARK: 验收 1：拿不到完整权限时不显示假 0/0、不盖「都存好了」的章

    func testOnlyFullAccessShowsCountsAndStamp() {
        for level in PhotoAccessLevel.allCases {
            let p = PhotoAccessPresentation.of(level)
            XCTAssertEqual(p.showsBackupCounts, level == .full, "\(level)")
            XCTAssertEqual(p.allowsAllBackedUpStamp, level == .full, "\(level)")
            XCTAssertEqual(p.notice == nil, level == .full, "\(level)：非完整授权必须有告示")
        }
    }

    // MARK: 验收 2：部分授权要说「现在只能前台备份」，并引导去完整授权

    func testLimitedAccessSaysForegroundOnlyAndGuidesToSettings() {
        let p = PhotoAccessPresentation.of(.limited)
        XCTAssertFalse(p.backgroundUploadPossible, "部分授权下后台上传通道整个不可用")
        XCTAssertEqual(p.notice?.titleKey, "photo_access.limited.title")
        XCTAssertEqual(p.notice?.bodyKey, "photo_access.limited.body")
        XCTAssertEqual(p.notice?.action, .openAppSettings)
        XCTAssertNotEqual(p.notice?.bodyKey, PhotoAccessPresentation.of(.denied).notice?.bodyKey, "部分 / 全拒各说各的（MOB-94）")
    }

    // MARK: 验收 3：引导卡能一键去设置（动作由 App 用 openSettingsURLString 执行）

    func testActionsPerLevel() {
        XCTAssertEqual(PhotoAccessPresentation.of(.denied).notice?.action, .openAppSettings)
        XCTAssertEqual(PhotoAccessPresentation.of(.notDetermined).notice?.action, .requestAccess, "没问过就直接弹系统授权框")
        XCTAssertNil(PhotoAccessPresentation.of(.restricted).notice?.action, "受限时去设置也改不了，不给无效按钮")
        XCTAssertNotEqual(PhotoAccessPresentation.of(.restricted).notice?.bodyKey, PhotoAccessPresentation.of(.denied).notice?.bodyKey)
    }

    func testKeysAreDistinctAndDotted() {
        XCTAssertEqual(Set(PhotoAccessPresentation.Keys.all).count, PhotoAccessPresentation.Keys.all.count)
        for key in PhotoAccessPresentation.Keys.all {
            XCTAssertTrue(key.hasPrefix("photo_access."), key)
        }
        let used = PhotoAccessLevel.allCases.compactMap { level in PhotoAccessPresentation.of(level).notice }
            .flatMap { n in [n.titleKey, n.bodyKey] + (n.actionKey.map { k in [k] } ?? []) }
        XCTAssertEqual(Set(used), Set(PhotoAccessPresentation.Keys.all), "列出的 key 都被用到、用到的都列出了（给 i18n 线核对）")
    }

    // MARK: 验收 4：uploadJobExtensionEnabled 为 false 时不得尝试建 job

    func testUploadGateRequiresFullAccessAndEnabledExtensionOnSupportedOS() {
        XCTAssertTrue(BackgroundUploadGate.mayCreateUploadJobs(level: .full, extensionEnabled: true))
        XCTAssertFalse(BackgroundUploadGate.mayCreateUploadJobs(level: .full, extensionEnabled: false), "开关关着不许建")
        XCTAssertFalse(BackgroundUploadGate.mayCreateUploadJobs(level: .full, extensionEnabled: nil), "iOS 26.1 以下没有这条通道")
        for level in PhotoAccessLevel.allCases where level != .full {
            XCTAssertFalse(BackgroundUploadGate.mayCreateUploadJobs(level: level, extensionEnabled: true), "\(level)：要完整授权")
        }
    }
}
