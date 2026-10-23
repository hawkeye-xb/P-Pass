// 配对核对页的字号层级：标题 > 电脑名 > 说明 > 指纹，在每一档系统字号（含辅助功能大字号）下都成立。
// 按系统的缩放规则（UIFontMetrics，与 SwiftUI relativeTo / ScaledMetric 同一套）把每一级换算成实际 pt 再比。
import SwiftUI
import UIKit
import XCTest
@testable import PPass

final class PairReviewTypeTests: XCTestCase {
    private let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    private func uiStyle(_ s: Font.TextStyle) -> UIFont.TextStyle {
        switch s {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }

    private func pt(_ level: PairReviewType.Level, _ c: UIContentSizeCategory) -> CGFloat {
        UIFontMetrics(forTextStyle: uiStyle(level.style)).scaledValue(for: level.size, compatibleWith: UITraitCollection(preferredContentSizeCategory: c))
    }

    func testHierarchyHoldsAtEveryContentSize() {
        for c in categories {
            let title = pt(PairReviewType.title, c), name = pt(PairReviewType.name, c)
            let body = pt(PairReviewType.body, c), fp = pt(PairReviewType.fingerprint, c)
            XCTAssertGreaterThan(title, name, "\(c.rawValue)：标题 \(title) 必须大于电脑名 \(name)")
            XCTAssertGreaterThan(name, body, "\(c.rawValue)：电脑名 \(name) 必须大于说明 \(body)")
            XCTAssertGreaterThan(body, fp, "\(c.rawValue)：说明 \(body) 必须大于指纹 \(fp)")
        }
    }

    /// 默认字号下的值就是 tokens.json（Android 基础值叠 platforms.ios）。
    func testDefaultSizesComeFromTokens() {
        XCTAssertEqual(pt(PairReviewType.title, .large), 30)
        XCTAssertEqual(pt(PairReviewType.name, .large), 22)
        XCTAssertEqual(pt(PairReviewType.body, .large), 17)
        XCTAssertEqual(pt(PairReviewType.fingerprint, .large), 15)
    }
}
