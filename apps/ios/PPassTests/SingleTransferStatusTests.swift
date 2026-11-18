@testable import PPass
import XCTest

/// #1789（父卡 #1784）：设置固定分组、两个单次入口只发起选择、单次状态只在英雄区出现。
///
/// SettingsScreen / HeroCard 是 SwiftUI 视图，单测里不渲染——与 Android
/// `SingleTransferStatusTest` 同一分工：源文本门禁锁「写法」，真机表现随版本验收台账验。
/// 判据本体（进度/结果句、中断不算失败）由 PickedLineTests 与 PPassCore 的 PickedUploadTests 守着。
final class SingleTransferStatusTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: RepoPaths.root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func group(_ source: String, _ marker: String) -> String? {
        guard let start = source.range(of: "// ── #1789 固定分组 \(marker)") else { return nil }
        let tail = source[start.upperBound...]
        guard let end = tail.range(of: "// ── #1789 固定分组") else { return nil }
        return String(tail[..<(end.lowerBound)])
    }

    /// #1784：设置按「自动备份 / 单次传输 / 传输条件与通知 / 更多」固定分组，组序固定。
    func testSettingsGroupsAreFixedAndInOrder() throws {
        let source = try source("apps/ios/PPass/Home/SettingsScreen.swift")
        let one = source.range(of: "// ── #1789 固定分组 1/4")?.lowerBound
        let two = source.range(of: "// ── #1789 固定分组 2/4")?.lowerBound
        let three = source.range(of: "// ── #1789 固定分组 3/4")?.lowerBound
        let four = source.range(of: "// ── #1789 固定分组 4/4")?.lowerBound
        XCTAssertNotNil(one, "缺「自动备份」分组标记")
        XCTAssertNotNil(two, "缺「单次传输」分组标记")
        XCTAssertNotNil(three, "缺「传输条件与通知」分组标记")
        XCTAssertNotNil(four, "缺「更多」分组标记")
        if let one, let two, let three, let four {
            XCTAssertTrue(one < two && two < three && three < four, "组序：自动备份 → 单次传输 → 传输条件与通知 → 更多")
        }
    }

    /// #1784：单次传输下固定为「从相册选择」「从文件选择」，两行只发起选择，不显示进度、结果或最近一批。
    func testTheTwoSingleTransferEntriesOnlyInitiateSelection() throws {
        let source = try source("apps/ios/PPass/Home/SettingsScreen.swift")
        let group = self.group(source, "2/4")
        XCTAssertNotNil(group, "缺「单次传输」分组")
        if let group {
            XCTAssertTrue(group.contains("pick_from_photos_label"), "「从相册选择」在单次传输组里")
            XCTAssertTrue(group.contains("pick_from_files_label"), "「从文件选择」在单次传输组里")
            XCTAssertTrue(group.contains("app.pickerRequested = true"), "相册入口发起选择")
            XCTAssertTrue(group.contains("showFilePicker = true"), "文件入口发起选择")
            XCTAssertFalse(group.contains("pickedBatch"), "入口行不显示进度 / 结果 / 最近一批")
            XCTAssertFalse(group.contains("picked_progress"), "入口行不带状态句")
        }
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
}
