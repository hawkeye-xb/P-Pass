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

    func testMixedScopeIsNotFolderOnlyAndKeepsLimitedPhotoBehavior() {
        let mixed = SourceAvailability(autoRule: true, photoAccess: .partial, hasUsableFolder: true, hasSelectedAlbum: true)
        XCTAssertFalse(mixed.folderOnly)
        XCTAssertFalse(mixed.showsGlobalPhotoBlock, "目录侧仍可继续，相册侧降级由统一英雄区处理")
    }

    func testFolderScopeUsesSelectionAndLegacyRegistration() {
        XCTAssertTrue(SourceAvailability.hasUsableFolder(selected: ["folder:a"], known: [], folderCount: 1))
        XCTAssertTrue(SourceAvailability.hasUsableFolder(selected: nil, known: [], folderCount: 1), "旧版目录没有新版勾选存值")
        XCTAssertFalse(SourceAvailability.hasUsableFolder(selected: [], known: ["folder:a"], folderCount: 1), "新版明确取消勾选不是有效目录范围")
        XCTAssertFalse(SourceAvailability.hasUsableFolder(selected: ["a"], known: [], folderCount: 0))
    }
}
