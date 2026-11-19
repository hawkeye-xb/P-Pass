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

    /// #1784：设置按「自动备份 / 单次传输 / 传输条件与通知」固定分组，组序固定。
    /// #1889：「更多」并入「传输条件与通知」组，不再单独成组，所以是三个分组。
    /// 评审 Cu：组序用各组的**实际控件**锚定（开关 / 入口行的标识），不只比注释位置——
    /// 只交换两个 Section 的内容、把注释留在原地，控件顺序一变本条就红。
    func testSettingsGroupsAreFixedAndInOrder() throws {
        let source = try source("apps/ios/PPass/Home/SettingsScreen.swift")
        let one = source.range(of: "// ── #1789 固定分组 1/3")?.lowerBound
        let two = source.range(of: "// ── #1789 固定分组 2/3")?.lowerBound
        let three = source.range(of: "// ── #1789 固定分组 3/3")?.lowerBound
        XCTAssertNotNil(one, "缺「自动备份」分组标记")
        XCTAssertNotNil(two, "缺「单次传输」分组标记")
        XCTAssertNotNil(three, "缺「传输条件与通知」分组标记")
        if let one, let two, let three {
            XCTAssertTrue(one < two && two < three, "组序：自动备份 → 单次传输 → 传输条件与通知（含「更多」）")
        }
        XCTAssertFalse(
            source.contains("// ── #1789 固定分组 4/"),
            "「更多」不再单独成组（不该再有自己的分组标记）",
        )
        // 各组的标志性行（组的第一行就是这组的名字）：位置必须落在自己组的标记之后、下一个组标记之前。
        // #1889：「更多」不再是组的第一行，改成钉住它落在第三组内、且在「通知」开关之后。
        let anchors: [(String, String, String)] = [
            ("route: .bucket", "// ── #1789 固定分组 1/3", "// ── #1789 固定分组 2/3"),
            ("pick_from_photos_label", "// ── #1789 固定分组 2/3", "// ── #1789 固定分组 3/3"),
            ("setting_wifi_only", "// ── #1789 固定分组 3/3", "// ── #1789 固定分组结束"),
            ("route: .more", "// ── #1789 固定分组 3/3", "// ── #1789 固定分组结束"),
        ]
        for (anchor, marker, next) in anchors {
            let position = source.range(of: anchor)?.lowerBound
            XCTAssertNotNil(position, "缺组标志性行：\(anchor)")
            let start = source.range(of: marker)?.lowerBound
            let end = source.range(of: next)?.lowerBound
            if let position, let start, let end {
                XCTAssertTrue(position > start && position < end, "行 \(anchor) 必须落在「\(marker)」组内")
            }
        }
        if let more = source.range(of: "route: .more")?.lowerBound,
           let notify = source.range(of: "rule_notify\"), isOn:")?.lowerBound {
            XCTAssertTrue(more > notify, "「更多」必须排在「通知」下面（并入同一组）")
        } else {
            XCTFail("缺「更多」或「通知」行，判不了同组关系")
        }
    }

    /// #1784：单次传输下固定为「从相册选择」「从文件选择」，两行只发起选择，不显示进度、结果或最近一批。
    /// 评审 Cy：逐个按钮核对标签与动作的配对——把两个按钮的动作互换，按「组里存在两个标签 + 两个动作」判的写法仍会通过。
    func testTheTwoSingleTransferEntriesOnlyInitiateSelection() throws {
        let source = try source("apps/ios/PPass/Home/SettingsScreen.swift")
        let group = self.group(source, "2/3")
        XCTAssertNotNil(group, "缺「单次传输」分组")
        if let group {
            // 按 Button 切开：每个入口块内，标签与动作必须一一配对。
            let buttons = group.components(separatedBy: "Button {").dropFirst()
            XCTAssertTrue(buttons.count >= 2, "单次传输组固定两行入口")
            XCTAssertTrue(
                buttons.contains { $0.contains("app.pickerRequested = true") && $0.contains("pick_from_photos_label") },
                "「从相册选择」必须配发起相册选择器（app.pickerRequested = true）",
            )
            XCTAssertTrue(
                buttons.contains { $0.contains("showFilePicker = true") && $0.contains("pick_from_files_label") },
                "「从文件选择」必须配发起文件选择器（showFilePicker = true）",
            )
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
