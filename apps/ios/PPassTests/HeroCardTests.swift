@testable import PPass
import PPassCore
import UIKit
import XCTest

/// #1962：英雄卡与 Android `HomeScreen.kt` 双端对齐的两处：
/// 1) 「从今天起」且 0/0 的空态一句话；2) 卡内紧凑描边次级按钮的样式常量。
/// 都是运行期可判定的纯值，不需要读仓库源文件。
final class HeroCardTests: XCTestCase {
    /// 反证：`showsFromTodayEmpty` 去掉 `since` 或 0/0 任一条件，对应断言红。
    func testShowsFromTodayEmptyOnlyForZeroTripletWithAStartDate() {
        let zero = BackupTriplet(n: 0, m: 0, lastSuccessAt: 0, confirmedRaw: 0)
        let nonZero = BackupTriplet(n: 1, m: 1, lastSuccessAt: 0, confirmedRaw: 1)
        let since = BackupSince.since(ms: 1_700_000_000_000)

        XCTAssertTrue(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: zero, since: since), "0/0 + 从今天起")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: zero, since: .all), "0/0 + 全部")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: zero, since: nil), "0/0 + 没存时间档")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: nonZero, since: since), "1/1 + 从今天起")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .accessBlocked, triplet: zero, since: since), "非三元组")
    }

    /// 中英文词条都存在且不是 fallback key（L.s 缺 key 会断言失败 / 返回 key 本身）。
    func testFromTodayEmptyCopyExistsInBothLanguages() {
        for lang in ["en", "zh-Hans"] {
            guard let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("缺 \(lang).lproj")
                continue
            }
            let missing = "\u{1}__missing__"
            let value = bundle.localizedString(forKey: "auto_backup_from_today_empty", value: missing, table: nil)
            XCTAssertNotEqual(value, missing, "\(lang) 缺 auto_backup_from_today_empty")
            XCTAssertNotEqual(value, "auto_backup_from_today_empty", "\(lang) 是 fallback key")
            XCTAssertFalse(value.isEmpty, "\(lang) 词条为空")
        }
    }

    /// 紧凑描边次级按钮的样式与 Android 英雄卡 OutlinedButton 对齐：
    /// 高 40、圆角 14、1pt 描边 @40%、act 字色、15pt 粗体。
    func testCompactActionButtonStyleMatchesAndroid() {
        let style = HeroActionButtonStyleConfig.standard
        XCTAssertEqual(style.height, 40)
        XCTAssertEqual(style.cornerRadius, 14)
        XCTAssertEqual(style.borderWidth, 1)
        XCTAssertEqual(style.borderOpacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(style.fontSize, 15)
        XCTAssertTrue(UIColor(style.contentColor).isEqual(UIColor(PPColor.act)), "文字颜色必须是 PPColor.act")

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(style.borderColor).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(a, 0.4, accuracy: 0.01, "描边是 act 的 40%")
    }

    /// 按钮组件确实按样式绘制：标题、动作都可传入（编译期契约 + 运行期构造不崩）。
    func testCompactActionButtonConstructsWithTitleAndAction() {
        var tapped = false
        let button = HeroCompactActionButton(title: L.s("auto_backup_blocked_action")) { tapped = true }
        XCTAssertEqual(button.title, L.s("auto_backup_blocked_action"))
        button.action()
        XCTAssertTrue(tapped)
    }

    /// #2082：英雄卡四档底色与分隔线颜色一一对应 tokens.json 语义色。
    func testHeroSurfaceToneColorsAndDividers() {
        XCTAssertEqual(HeroCard.surfaceBackground(.act), PPColor.actBg)
        XCTAssertEqual(HeroCard.dividerColor(.act), PPColor.act.opacity(0.18))
        XCTAssertEqual(HeroCard.surfaceBackground(.waiting), PPColor.waitingBg)
        XCTAssertEqual(HeroCard.dividerColor(.waiting), PPColor.waiting.opacity(0.18))
        XCTAssertEqual(HeroCard.surfaceBackground(.neutral), PPColor.linen)
        XCTAssertEqual(HeroCard.dividerColor(.neutral), PPColor.hairline)
        XCTAssertEqual(HeroCard.surfaceBackground(.safe), PPColor.safeBg)
        XCTAssertEqual(HeroCard.dividerColor(.safe), PPColor.safe.opacity(0.18))
    }

    /// #2082：上半区 lastLine 只显示最近成功，即使 k > 0 也不再拼接待备份张数（避免与下半区 state_pending 重复）。
    func testLastLineDoesNotAppendPendingCountWhenKIsPositive() {
        let withPending = BackupTriplet(n: 10, m: 4, lastSuccessAt: 1_700_000_000_000, confirmedRaw: 4)
        let zeroPending = BackupTriplet(n: 10, m: 10, lastSuccessAt: 1_700_000_000_000, confirmedRaw: 10)
        XCTAssertEqual(HeroCard.lastLine(withPending), HeroCard.lastLine(zeroPending))
        XCTAssertFalse(HeroCard.lastLine(withPending).contains("·"))
    }
}
