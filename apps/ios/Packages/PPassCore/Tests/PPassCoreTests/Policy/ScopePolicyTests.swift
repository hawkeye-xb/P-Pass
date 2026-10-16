// #983：相册范围语义与 Android 同口径。
// - 新增相册判定：MainActivity `added = if (prevScope == null) sel else sel - prevScope`，非空才触发 SCOPE_ADDED。
// - 「已选相册」计数：HomeScreen `selectedExistingCount`（#836）——已选且当前存在。
import XCTest
@testable import PPassCore

final class ScopePolicyTests: XCTestCase {
    func testFirstSaveEverySelectedAlbumIsAdded() {
        XCTAssertEqual(ScopePolicy.added(previous: nil, selected: ["a", "b"]), ["a", "b"])
    }

    func testOnlyNewlySelectedAlbumsAreAdded() {
        XCTAssertEqual(ScopePolicy.added(previous: ["a"], selected: ["a", "b"]), ["b"])
    }

    /// 原样保存、减少相册：什么都没新增 → 不触发。
    func testUnchangedOrShrunkScopeAddsNothing() {
        XCTAssertTrue(ScopePolicy.added(previous: ["a", "b"], selected: ["a", "b"]).isEmpty)
        XCTAssertTrue(ScopePolicy.added(previous: ["a", "b"], selected: ["a"]).isEmpty)
        XCTAssertTrue(ScopePolicy.added(previous: ["a", "b"], selected: []).isEmpty)
    }

    func testFirstSaveOfEmptySelectionAddsNothing() {
        XCTAssertTrue(ScopePolicy.added(previous: nil, selected: []).isEmpty)
    }

    func testCountOnlyCountsSelectedAndExisting() {
        XCTAssertEqual(ScopePolicy.selectedExistingCount(selected: ["a", "b", "gone"], existing: ["a", "b", "c"]), 2)
    }

    /// 所选全被删：计数 0（首页据此显示「没有可备份的相册」）。
    func testAllSelectedDeletedCountsZero() {
        XCTAssertEqual(ScopePolicy.selectedExistingCount(selected: ["x", "y"], existing: ["a"]), 0)
    }

    func testNeverSavedIsNil() {
        XCTAssertNil(ScopePolicy.selectedExistingCount(selected: nil, existing: ["a"]))
        XCTAssertNil(ScopePolicy.selectedExistingCount(selected: nil, existing: nil))
    }

    /// 读不到相册（无完整授权）：无从判断哪些还在，沿用已选个数（与 Android 同）。
    func testUnknownExistingFallsBackToSavedSize() {
        XCTAssertEqual(ScopePolicy.selectedExistingCount(selected: ["a", "b"], existing: nil), 2)
    }
}
