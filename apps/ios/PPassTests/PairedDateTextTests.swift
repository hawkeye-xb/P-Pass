import XCTest
@testable import PPass

/// #1206：「存储电脑」的配对日期按界面语言给本地化长日期，不写死中文格式串（与 Android `pairedDateText` 同一对结果）。
/// E2 反证：把实现改回 `dateFormat = "yyyy年M月d日"`，下面两条用例都会红。
final class PairedDateTextTests: XCTestCase {
    /// 本地 2026-10-14 正午：无论模拟器在哪个时区，格式化出来都是 10 月 14 日。
    private var pairedAt: Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    func testChineseLocaleKeepsChineseLongDateAndFollowsLocale() {
        let zh = PairedDateText.format(pairedAt: pairedAt, locale: Locale(identifier: "zh_Hans_CN"))
        XCTAssertEqual(zh, "2026年10月14日")
        // 同一时间戳换 locale 必须换写法——写死中文格式串时这里会相等。
        XCTAssertNotEqual(zh, PairedDateText.format(pairedAt: pairedAt, locale: Locale(identifier: "en_US")),
                          "日期格式没有跟随界面语言")
    }

    func testUSEnglishLocaleUsesEnglishLongDate() {
        let en = PairedDateText.format(pairedAt: pairedAt, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(en, "October 14, 2026")
        for cjk in ["年", "月", "日"] {
            XCTAssertFalse(en.contains(cjk), "英文界面不该出现「\(cjk)」：\(en)")
        }
    }
}
