@testable import PPass
import XCTest

final class SingleTransferStatusTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: RepoPaths.root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testSettingsGroupsAreFixedAndInOrder() {
        XCTAssertEqual(SettingsLayout.sections, [.backup, .selection, .conditions])
        XCTAssertEqual(SettingsLayout.conditionRows, [.wifi, .notifications, .more])
    }

    func testBackupScopeRowRequiresAutoBackupRule() {
        XCTAssertEqual(SettingsLayout.backupRows(autoRule: false), [.rule])
        XCTAssertEqual(SettingsLayout.backupRows(autoRule: true), [.rule, .scope, .background])
    }

    func testTheTwoSingleTransferEntriesOnlyInitiateSelection() {
        var requested: [String] = []
        let entries = SettingsLayout.selectionRows
        XCTAssertEqual(entries.map(\.labelKey), ["pick_from_photos_label", "pick_from_files_label"])
        let photos = { requested.append("photos") }
        let files = { requested.append("files") }
        entries[0].request(photos: photos, files: files)
        XCTAssertEqual(requested, ["photos"])
        entries[1].request(photos: photos, files: files)
        XCTAssertEqual(requested, ["photos", "files"])
    }

    func testSingleTransferListRowsUseNativeListRowHeightAndDisclosure() {
        for entry in SettingsLayout.selectionRows {
            let row = entry.listRow(action: {})
            XCTAssertNil(row.minimumHeight)
            XCTAssertEqual(row.disclosureSymbol, "chevron.right")
        }
        let standalone = SingleTransferSelectionRow(title: "Photos", action: {})
        XCTAssertEqual(standalone.minimumHeight, PPUI.Layout.rowMinHeight)
    }

    /// #1784：设置页不再有「挑几张传」的进度/结果行——单次状态只在英雄区出现。
    func testNoPickProgressLineIsLeftInTheSettingsCard() throws {
        let settings = try source("apps/ios/PPass/Home/SettingsScreen.swift")
        XCTAssertFalse(settings.contains("pickedLine"), "设置页不再渲染单次传输的进度/结果句")
        let hero = try source("apps/ios/PPass/Home/HeroCard.swift")
        XCTAssertTrue(hero.contains("HomeProjection.pickedLine(app.pickedBatch)"), "英雄区消费单次传输的进度/结果句")
    }

    /// #1784：条件行只在原组内显隐、尊重系统减少动态效果——状态变化直接呈现，不加过渡动画。
    func testSettingsAndHeroRenderStateDirectlyWithoutTransitions() throws {
        for file in ["apps/ios/PPass/Home/SettingsScreen.swift", "apps/ios/PPass/Home/HeroCard.swift"] {
            let source = try source(file)
            for api in ["withAnimation", ".animation(", ".transition(", "animatableData"] {
                XCTAssertFalse(source.contains(api), "\(file) 直接呈现状态，不使用 \(api)（尊重系统减少动态效果）")
            }
        }
    }

    /// #1962：设置页二级路由（范围 / 存储详情 / 诊断 / 更多）隐藏底部双 Tab 栏，对齐 Android 二级页
    /// 收起 Photos/设置 tab 栏。反证：去掉 `.toolbar(.hidden, for: .tabBar)`，本条判红。
    func testSecondaryRoutesHideTheBottomTabBar() throws {
        let settings = try source("apps/ios/PPass/Home/SettingsScreen.swift")
        let nav = try XCTUnwrap(settings.range(of: ".navigationDestination(for: Route.self)")?.lowerBound)
        let slice = String(settings[nav...].prefix(800))
        XCTAssertTrue(slice.contains(".toolbar(.hidden, for: .tabBar)"), "二级路由必须隐藏底部 tabBar")
        let destination = try XCTUnwrap(settings.range(of: "func secondaryDestination(")?.lowerBound)
        let body = String(settings[destination...])
        for route in [".bucket", ".storage", ".diagnostics", ".more"] {
            XCTAssertTrue(body.contains("case \(route)"), "二级路由必须覆盖 \(route)")
        }
    }
}
