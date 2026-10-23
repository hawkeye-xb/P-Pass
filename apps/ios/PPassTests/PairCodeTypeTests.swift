// 配对验证码页的主次：验证码 > 电脑名 > 说明 > 电脑标识，在每一档系统字号（含辅助功能大字号）下都成立。
// 按系统的缩放规则（UIFontMetrics，与 SwiftUI 的 relativeTo / 系统文字样式同一套）把每一级换算成实际 pt 再比。
import SwiftUI
import UIKit
import XCTest
@testable import PPass

final class PairCodeTypeTests: XCTestCase {
    private let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    /// 验证码页每一级在系统字号 [c] 下的实际 pt。两种缩放规则不同，分开算：
    /// - 系统字体的文字样式（PPFont.pairCode = 等宽 largeTitle、monoSmall = 等宽 footnote）按系统字号表走（preferredFont）；
    /// - 品牌字体（PPFont.title3 / body，`Font.custom(relativeTo:)`）按 UIFontMetrics 缩放；电脑名封顶在 PairCodeView.nameCap。
    private func system(_ style: UIFont.TextStyle, _ c: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: c)).pointSize
    }

    private func custom(_ size: CGFloat, _ style: UIFont.TextStyle, _ c: UIContentSizeCategory) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: c))
    }

    private func capped(_ c: UIContentSizeCategory) -> UIContentSizeCategory {
        let cap = UIContentSizeCategory(PairCodeView.nameCap)
        return c > cap ? cap : c
    }

    func testHierarchyHoldsAtEveryContentSize() {
        for c in categories {
            let code = system(.largeTitle, c), n = custom(PPUI.TextSize.pairName, .title3, capped(c))
            let b = custom(PPUI.TextSize.pairBody, .body, c), i = system(.footnote, c)
            XCTAssertGreaterThan(code, n, "\(c.rawValue)：验证码 \(code) 必须大于电脑名 \(n)")
            XCTAssertGreaterThan(n, b, "\(c.rawValue)：电脑名 \(n) 必须大于说明 \(b)")
            XCTAssertGreaterThan(b, i, "\(c.rawValue)：说明 \(b) 必须大于标识 \(i)")
        }
    }

    /// tokens.json 登记的 iOS 值就是 PPFont 语义样式的基准字号（pairCode / monoSmall 是系统样式，取系统默认档的字号）。
    func testRegisteredSizesAreThePPFontStyles() {
        XCTAssertEqual(PPUI.TextSize.pairCode, system(.largeTitle, .large), "PPFont.pairCode")
        XCTAssertEqual(PPUI.TextSize.pairName, 24, "PPFont.title3")
        XCTAssertEqual(PPUI.TextSize.pairBody, PPSize.bodyMin, "PPFont.body")
        XCTAssertEqual(PPUI.TextSize.pairIdentity, system(.footnote, .large), "PPFont.monoSmall")
        XCTAssertEqual(PPUI.TextSize.pairLabel, 12, "PPFont.captionBold")
    }
}
