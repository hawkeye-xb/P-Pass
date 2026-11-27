@testable import PPass
import XCTest

/// 设置页的分组结构、单次传输入口与二级路由：
/// 分组顺序、范围行随自动备份开关显隐、两个单次入口各自只发起对应的选择、
/// 二级路由映射，以及决定页 / 范围编辑器的导航与返回接线。
@MainActor
final class SingleTransferStatusTests: XCTestCase {
    func testSettingsGroupsAreFixedAndInOrder() {
        XCTAssertEqual(SettingsLayout.sections, [.backup, .selection, .conditions])
        XCTAssertEqual(SettingsLayout.conditionRows, [.wifi, .notifications, .more])
        XCTAssertNil(SettingsLayout.Group.backup.headerKey)
        XCTAssertEqual(SettingsLayout.Group.selection.headerKey, "settings_section_single_transfer")
        XCTAssertEqual(SettingsLayout.Group.conditions.headerKey, "settings_section_preferences")
    }

    func testVisualHierarchyCopyAndBackupTabSymbol() throws {
        let en = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let zh = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(en.localizedString(forKey: "settings_section_single_transfer", value: "\u{1}", table: nil), "Send once")
        XCTAssertEqual(zh.localizedString(forKey: "settings_section_single_transfer", value: "\u{1}", table: nil), "单次手动传")
        XCTAssertEqual(en.localizedString(forKey: "settings_section_preferences", value: "\u{1}", table: nil), "Preferences")
        XCTAssertEqual(zh.localizedString(forKey: "settings_section_preferences", value: "\u{1}", table: nil), "偏好与更多")
        XCTAssertEqual(en.localizedString(forKey: "decision_single_transfer_prompt", value: "\u{1}", table: nil), "Or send a few manually")
        XCTAssertEqual(zh.localizedString(forKey: "decision_single_transfer_prompt", value: "\u{1}", table: nil), "或先手动传几张")
        XCTAssertEqual(en.localizedString(forKey: "tab_settings", value: "\u{1}", table: nil), "Backup")
        XCTAssertEqual(zh.localizedString(forKey: "tab_settings", value: "\u{1}", table: nil), "备份")
        XCTAssertFalse(MainTabs.backupTabSymbol.lowercased().contains("cloud"))
        XCTAssertEqual(MainTabs.backupTabSymbol, "arrow.triangle.2.circlepath")
    }

    func testBackupScopeRowRequiresAutoBackupRule() {
        XCTAssertEqual(SettingsLayout.backupRows(autoRule: false), [.rule])
        XCTAssertEqual(SettingsLayout.backupRows(autoRule: true), [.rule, .scope, .background])
    }

    func testTheTwoSingleTransferEntriesOnlyInitiateSelection() {
        var requested: [String] = []
        let entries = SettingsLayout.selectionRows
        XCTAssertEqual(entries.map(\.labelKey), ["pick_from_photos_label", "pick_from_files_label"])
        XCTAssertEqual(entries.map(\.accessibilityID), ["pickPhotosRow", "pickFilesRow"], "读屏与端到端靠这两个标识定位入口")
        let photos = { requested.append("photos") }
        let files = { requested.append("files") }
        entries[0].request(photos: photos, files: files)
        XCTAssertEqual(requested, ["photos"])
        entries[1].request(photos: photos, files: files)
        XCTAssertEqual(requested, ["photos", "files"])
    }

    /// 二级路由：只有「备份范围」与「更多」有二级页，开关行不参与导航。
    func testSettingsRowsMapToTheirNativeRoutes() {
        XCTAssertEqual(SettingsLayout.Backup.scope.route, .bucket)
        XCTAssertNil(SettingsLayout.Backup.rule.route)
        XCTAssertNil(SettingsLayout.Backup.background.route)
        XCTAssertEqual(SettingsLayout.Condition.more.route, .more)
        XCTAssertNil(SettingsLayout.Condition.wifi.route)
        XCTAssertNil(SettingsLayout.Condition.notifications.route)
        XCTAssertEqual(Set(SettingsScreen.Route.allCases),
                       Set([SettingsScreen.Route.bucket, .storage, .diagnostics, .more, .about]))
    }

    /// 决定页主按钮进范围页，范围页返回回到决定页；两个单次入口各自只打开对应的选择器。
    func testDecisionNavigationAndPickerEntries() {
        let app = AppModel(backend: FakeBackend.make(.normal))
        app.phase = .decision

        app.decisionChooseScope()
        XCTAssertEqual(app.phase, .chooseAlbums, "主按钮进范围页")
        XCTAssertTrue(app.autoRule)

        app.leaveFirstScope()
        XCTAssertEqual(app.phase, .decision, "范围页返回回到决定页")

        app.decisionPickPhotos()
        XCTAssertTrue(app.pickerRequested, "照片入口只打开照片选择器")
        XCTAssertFalse(app.filePickerRequested)
        app.pickerRequested = false
        XCTAssertFalse(app.decisionBusy, "选择器关闭后解锁")

        app.decisionPickFiles()
        XCTAssertTrue(app.filePickerRequested, "文件入口只打开文件选择器")
        XCTAssertFalse(app.pickerRequested)
    }

    /// 范围编辑入口：英雄卡「调整范围」选中设置 Tab 并请求打开范围页，由 SettingsScreen 消费。
    func testScopeEditorActionSelectsSettingsAndRequestsTheRoute() {
        let app = AppModel(backend: FakeBackend.make(.normal))
        app.tab = .photos
        app.adjustScopeFromIncompleteAlbum()
        XCTAssertEqual(app.tab, .settings)
        XCTAssertTrue(app.wantsScopeEditor)
    }

    /// 手动输入页的返回：从扫码页进来回扫码页，从欢迎页进来回欢迎页。
    func testManualPairBackReturnsToWhereItCameFrom() {
        XCTAssertEqual(OnboardingFlow.manualBackTarget(fromScan: true), .scan)
        XCTAssertEqual(OnboardingFlow.manualBackTarget(fromScan: false), .welcome)
    }
}
