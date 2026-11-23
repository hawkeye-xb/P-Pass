@testable import PPass
import XCTest

/// #1962：照片页引导位的「首次引导只发生一次」守卫（对位 Android `scopeNeedsFirstChoice`，
/// 产品负责人 2026-11-17 口径）。保存过任何范围（含空集）后主动关掉规则，不再反复弹
/// 「开启范围备份」；只有从未保存过范围且没有既有目录才算「还没定过」。
final class PhotosGuideTests: XCTestCase {
    private func facts(scopeOn: Bool = false, firstUploaded: Bool = false, backgroundOn: Bool = false,
                       finished: Bool = false, firstChoicePending: Bool = true) -> GuideFacts {
        GuideFacts(scopeOn: scopeOn, firstUploaded: firstUploaded, backgroundOn: backgroundOn,
                   finished: finished, firstChoicePending: firstChoicePending)
    }

    /// 反证：`photosGuideOf` 去掉 `firstChoicePending` 守卫，本条红（会退回 `.enableScope`）。
    func testFirstChoicePendingStillAsksForTheFirstChoice() {
        XCTAssertEqual(AppModel.photosGuideOf(facts(scopeOn: false, firstChoicePending: true)), .enableScope)
    }

    /// 保存过范围（含空集）或文件夹一套：不再主动引导「开启范围备份」。
    func testSavedChoiceSuppressesTheFirstChoiceBanner() {
        XCTAssertEqual(AppModel.photosGuideOf(facts(scopeOn: false, firstChoicePending: false)), .none)
    }

    /// 真 `AppModel`：演示数据已保存过范围，再主动关掉规则 → 引导横幅不再出现。
    /// 反证：`guideFacts.firstChoicePending` 不看已存范围（恒为 true），本条红。
    @MainActor
    func testSavedScopeThenRuleOffDoesNotShowTheGuideAgain() {
        let app = AppModel(backend: FakeBackend.make(.normal))
        XCTAssertTrue(app.autoRule, "演示数据规则默认开着")
        XCTAssertNotNil(app.scope, "演示数据已保存过范围")
        app.setAutoRule(false)
        XCTAssertFalse(app.autoRule)
        XCTAssertEqual(app.photosGuide, .none, "保存过范围后主动关掉规则：正常状态，不再弹引导")
    }

    /// 第一步按钮词条统一收口：完整权限 / folder-only 都是「开启」；纯相册有限授权才说「去设置」。
    /// 反证：退回 `photos_first_run_enable` 或 `background_refresh_notice_action`，对应用例红。
    @MainActor
    func testScopeGuideActionKeyUsesTheSharedEnableAndBlockedKeys() async throws {
        let full = AppModel(backend: FakeBackend.make(.normal))
        full.setAutoRule(false)
        XCTAssertEqual(full.scopeGuideActionKey, "photos_guide_enable", "完整权限：按钮是「开启」")

        let partial = AppModel(backend: FakeBackend.make(.partialAccess))
        partial.setAutoRule(false)
        XCTAssertEqual(partial.scopeGuideActionKey, "auto_backup_blocked_action", "纯相册有限授权：按钮是「去设置」")

        let folderBackend = FakeBackend.make(.partialAccess)
        let engine = try XCTUnwrap(folderBackend.engine as? FakeEngine)
        try await engine.addFolderSource(at: URL(fileURLWithPath: "/tmp/ppass-guide-folder"), displayName: "相机")
        let folderOnly = AppModel(backend: folderBackend)
        folderOnly.setAutoRule(false)
        XCTAssertEqual(folderOnly.scopeGuideActionKey, "photos_guide_enable", "folder-only：按钮是「开启」，不去设置")
    }
}
