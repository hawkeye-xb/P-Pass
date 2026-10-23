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

    /// 核对页用的 PPFont 语义样式（PPStyle.swift）：title2 = 衬线 30 随 title2、title3 = 衬线 24 随 title3、
    /// body = 17 随 body、monoSmall = 系统等宽 footnote（13）。字号与 tokens.json 的 iOS 登记值核对，样式与 PPFont 一致。
    private typealias Level = (size: CGFloat, style: Font.TextStyle)
    private let titleLevel: Level = (PPUI.TextSize.pairTitle, .title2)
    private let nameLevel: Level = (PPUI.TextSize.pairName, .title3)
    private let bodyLevel: Level = (PPUI.TextSize.pairBody, .body)
    private let fingerprintLevel: Level = (PPUI.TextSize.pairFingerprint, .footnote)

    private func pt(_ level: Level, _ c: UIContentSizeCategory) -> CGFloat {
        UIFontMetrics(forTextStyle: uiStyle(level.style)).scaledValue(for: level.size, compatibleWith: UITraitCollection(preferredContentSizeCategory: c))
    }

    func testHierarchyHoldsAtEveryContentSize() {
        for c in categories {
            let t = pt(titleLevel, c), n = pt(nameLevel, c), b = pt(bodyLevel, c), f = pt(fingerprintLevel, c)
            XCTAssertGreaterThan(t, n, "\(c.rawValue)：标题 \(t) 必须大于电脑名 \(n)")
            XCTAssertGreaterThan(n, b, "\(c.rawValue)：电脑名 \(n) 必须大于说明 \(b)")
            XCTAssertGreaterThan(b, f, "\(c.rawValue)：说明 \(b) 必须大于指纹 \(f)")
        }
    }

    /// tokens.json 登记的 iOS 值就是 PPFont 语义样式的基准字号（monoSmall 是系统 footnote，默认 13）。
    func testRegisteredSizesAreThePPFontStyles() {
        XCTAssertEqual(PPUI.TextSize.pairTitle, 30, "PPFont.title2")
        XCTAssertEqual(PPUI.TextSize.pairName, 24, "PPFont.title3")
        XCTAssertEqual(PPUI.TextSize.pairBody, PPSize.bodyMin, "PPFont.body")
        XCTAssertEqual(PPUI.TextSize.pairFingerprint, UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize, "PPFont.monoSmall")
        XCTAssertEqual(PPUI.TextSize.pairLabel, 12, "PPFont.captionBold")
    }
}
