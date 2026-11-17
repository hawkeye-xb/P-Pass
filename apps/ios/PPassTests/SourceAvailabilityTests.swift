import XCTest
@testable import PPass

final class SourceAvailabilityTests: XCTestCase {
    func testFolderOnlyDoesNotShowGlobalPhotoBlock() {
        let facts = SourceAvailability(autoRule: true, photoAccess: .none, hasUsableFolder: true, hasSelectedAlbum: false)
        XCTAssertTrue(facts.folderOnly)
        XCTAssertFalse(facts.showsGlobalPhotoBlock)
    }

    func testNoUsableFolderKeepsGlobalPhotoBlockOnlyWhenRuleIsOn() {
        XCTAssertTrue(SourceAvailability(autoRule: true, photoAccess: .none, hasUsableFolder: false, hasSelectedAlbum: true).showsGlobalPhotoBlock)
        XCTAssertFalse(SourceAvailability(autoRule: false, photoAccess: .none, hasUsableFolder: false, hasSelectedAlbum: true).showsGlobalPhotoBlock)
    }

    /// #1811：目录 + 相册混合、照片权限未完整：文件夹还在传，英雄区只说「相册未完整授权」并给「调整范围」，
    /// 不再出「自动备份已停止」，也不用相册-only 的「去设置」出口。
    func testMixedScopeShowsIncompleteAlbumInsteadOfStopped() {
        let partial = SourceAvailability(autoRule: true, photoAccess: .partial, hasUsableFolder: true, hasSelectedAlbum: true)
        XCTAssertFalse(partial.folderOnly)
        XCTAssertFalse(partial.showsGlobalPhotoBlock)
        XCTAssertTrue(partial.mixedAlbumIncomplete)
        XCTAssertTrue(partial.hasUsableSource, "文件夹还能备份")
        let denied = SourceAvailability(autoRule: true, photoAccess: .none, hasUsableFolder: true, hasSelectedAlbum: true)
        XCTAssertFalse(denied.showsGlobalPhotoBlock)
        XCTAssertTrue(denied.mixedAlbumIncomplete)
        XCTAssertFalse(denied.showsDeniedPhotoHint, "文件夹照常，不说「自动备份没开」")
        let ruleOff = SourceAvailability(autoRule: false, photoAccess: .none, hasUsableFolder: true, hasSelectedAlbum: true)
        XCTAssertFalse(ruleOff.mixedAlbumIncomplete, "规则关着是正常状态，不出状态卡")
    }

    /// #1811：只有目录时照片权限变差不产生停止状态，也不给「去设置」出口——目录备份仍在继续。
    func testFolderOnlyKeepsNoStopStateForAnyPhotoAccess() {
        for access in [MediaAccess.partial, .none] {
            let facts = SourceAvailability(autoRule: true, photoAccess: access, hasUsableFolder: true, hasSelectedAlbum: false)
            XCTAssertFalse(facts.showsGlobalPhotoBlock, "\(access)")
            XCTAssertFalse(facts.mixedAlbumIncomplete, "\(access)")
            XCTAssertTrue(facts.hasUsableSource, "\(access)")
        }
    }

    /// 通知侧判定与页面同一份口径：目录可用，或完整授权下已选且存在的相册，才算有可用来源。
    func testUsableSourceFactMatchesWhatCanStillBeBackedUp() {
        XCTAssertTrue(SourceAvailability.usableSource(selected: ["folder:f1"], known: [], folderCount: 1, existingAlbums: nil, photoAccess: .none))
        XCTAssertTrue(SourceAvailability.usableSource(selected: nil, known: [], folderCount: 1, existingAlbums: nil, photoAccess: .none), "旧版目录没有勾选存值")
        XCTAssertFalse(SourceAvailability.usableSource(selected: [], known: ["folder:f1"], folderCount: 1, existingAlbums: nil, photoAccess: .none), "明确取消勾选不是有效目录范围")
        XCTAssertTrue(SourceAvailability.usableSource(selected: ["a"], known: [], folderCount: 0, existingAlbums: ["a"], photoAccess: .full))
        XCTAssertFalse(SourceAvailability.usableSource(selected: ["a"], known: [], folderCount: 0, existingAlbums: ["a"], photoAccess: .partial), "有限授权：相册不进自动范围")
        XCTAssertFalse(SourceAvailability.usableSource(selected: [], known: [], folderCount: 0, existingAlbums: nil, photoAccess: .full))
    }

    func testFolderOnlyDoesNotShowDeniedPhotoHintOrFullAccessRoute() {
        let folderOnly = SourceAvailability(autoRule: true, photoAccess: .none, hasUsableFolder: true, hasSelectedAlbum: false)
        XCTAssertFalse(folderOnly.showsDeniedPhotoHint)
        let partialFolderOnly = SourceAvailability(autoRule: false, photoAccess: .partial, hasUsableFolder: true, hasSelectedAlbum: false)
        XCTAssertFalse(partialFolderOnly.needsFullPhotoAccessSettings)
    }

    func testAlbumOnlyKeepsLegacyPhotoPermissionRoute() {
        let denied = SourceAvailability(autoRule: true, photoAccess: .none, hasUsableFolder: false, hasSelectedAlbum: true)
        XCTAssertTrue(denied.showsDeniedPhotoHint)
        let partial = SourceAvailability(autoRule: false, photoAccess: .partial, hasUsableFolder: false, hasSelectedAlbum: true)
        XCTAssertTrue(partial.needsFullPhotoAccessSettings)
    }

    func testFolderScopeUsesSelectionAndLegacyRegistration() {
        XCTAssertTrue(SourceAvailability.hasUsableFolder(selected: ["folder:a"], known: [], folderCount: 1))
        XCTAssertTrue(SourceAvailability.hasUsableFolder(selected: nil, known: [], folderCount: 1), "旧版目录没有新版勾选存值")
        XCTAssertFalse(SourceAvailability.hasUsableFolder(selected: [], known: ["folder:a"], folderCount: 1), "新版明确取消勾选不是有效目录范围")
        XCTAssertFalse(SourceAvailability.hasUsableFolder(selected: ["a"], known: [], folderCount: 0))
    }
}
