@testable import PPass
import SwiftUI
import UIKit
import XCTest

@MainActor
final class AboutScreenTests: XCTestCase {
    private func firstCollectionView(in root: UIView) -> UICollectionView? {
        if let cv = root as? UICollectionView { return cv }
        for sub in root.subviews {
            if let found = firstCollectionView(in: sub) { return found }
        }
        return nil
    }

    private func allLabelsText(in root: UIView) -> [String] {
        var out: [String] = []
        if let label = root as? UILabel, let text = label.text, !text.isEmpty {
            out.append(text)
        }
        for sub in root.subviews {
            out.append(contentsOf: allLabelsText(in: sub))
        }
        return out
    }

    private func hostAboutScreen(
        bundle: Bundle,
        preferredLanguages: [String],
        sizeCategory: ContentSizeCategory,
        versionLine: String = "0.12.1 (72)",
        viewportHeight: CGFloat = 1600
    ) throws -> (window: UIWindow, host: UIHostingController<AnyView>, collectionView: UICollectionView) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "宿主 App 必须提供可用的 UIWindowScene"
        )
        let view = AnyView(
            NavigationStack {
                AboutScreen(
                    bundle: bundle,
                    preferredLanguages: preferredLanguages,
                    versionLine: versionLine
                )
            }
            .environment(\.sizeCategory, sizeCategory)
        )
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: viewportHeight)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let cv = try XCTUnwrap(
            firstCollectionView(in: host.view),
            "AboutScreen 必须基于原生 List（UICollectionView）渲染"
        )
        cv.layoutIfNeeded()
        return (window, host, cv)
    }

    func testAboutCopyLocalizedInBothLanguages() throws {
        let en = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let zh = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))

        XCTAssertEqual(L.s("about_label", bundle: en), "About")
        XCTAssertEqual(L.s("about_label", bundle: zh), "关于")
        XCTAssertEqual(L.s("about_tagline", bundle: en), "A cross-platform family photo hub, without the server setup.")
        XCTAssertEqual(L.s("about_tagline", bundle: zh), "跨生态家庭的照片中心，不用自己搭服务器。")
        XCTAssertEqual(L.s("about_source_license", bundle: en), "AGPL-3.0")
        XCTAssertEqual(L.s("about_source_license", bundle: zh), "AGPL-3.0")

        for key in [
            "about_website",
            "about_faq",
            "about_feedback_email",
            "about_feedback_discussions",
            "about_source_code",
            "about_privacy",
        ] {
            XCTAssertNotEqual(L.s(key, bundle: en), key)
            XCTAssertNotEqual(L.s(key, bundle: zh), key)
        }
    }

    func testAboutLinksMatchLanguageAndIncludeRequiredDestinations() {
        XCTAssertTrue(AboutLinks.isChinese(preferredLanguages: ["zh-Hans-CN"]))
        XCTAssertTrue(AboutLinks.isChinese(preferredLanguages: ["zh-TW"]))
        XCTAssertFalse(AboutLinks.isChinese(preferredLanguages: ["en-US"]))
        XCTAssertFalse(AboutLinks.isChinese(preferredLanguages: []))

        let en = AboutLinks.items(isChinese: false)
        XCTAssertEqual(
            en.map(\.url.absoluteString),
            [
                "https://p-pass.hawkeye-xb.com/",
                "https://p-pass.hawkeye-xb.com/faq/",
                "mailto:ppass@hawkeye-xb.com",
                "https://github.com/hawkeye-xb/P-Pass/discussions",
                "https://github.com/hawkeye-xb/P-Pass",
                "https://p-pass.hawkeye-xb.com/privacy/",
            ]
        )
        XCTAssertEqual(en.first { $0.id == "feedback_email" }?.value, "ppass@hawkeye-xb.com")
        XCTAssertEqual(en.first { $0.id == "source" }?.value, "AGPL-3.0")

        let zh = AboutLinks.items(isChinese: true)
        XCTAssertEqual(
            zh.map(\.url.absoluteString),
            [
                "https://p-pass.hawkeye-xb.com/zh/",
                "https://p-pass.hawkeye-xb.com/zh/faq/",
                "mailto:ppass@hawkeye-xb.com",
                "https://github.com/hawkeye-xb/P-Pass/discussions",
                "https://github.com/hawkeye-xb/P-Pass",
                "https://p-pass.hawkeye-xb.com/zh/privacy/",
            ]
        )
    }

    func testAboutScreenRendersHeaderAndAllSixLinksInBothLanguagesAt1_5xText() throws {
        // 1.5× 动态字号下，body(17pt) 至少放大至 25.5pt（UIFontMetrics .accessibilityMedium 实测为 28pt ≥ 1.5×）。
        let scale15Trait = UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)
        let scaledBody = UIFontMetrics(forTextStyle: .body).scaledValue(for: PPSize.bodyMin, compatibleWith: scale15Trait)
        XCTAssertGreaterThanOrEqual(scaledBody, PPSize.bodyMin * 1.5, "测试档位须达到至少 1.5× 放大倍数")

        let enBundle = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let zhBundle = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))

        for (label, bundle, langs, expectedTitle) in [
            ("en", enBundle, ["en-US"], "About"),
            ("zh-Hans", zhBundle, ["zh-Hans-CN"], "关于"),
        ] {
            let (win, host, cv) = try hostAboutScreen(
                bundle: bundle,
                preferredLanguages: langs,
                sizeCategory: .accessibilityMedium
            )
            defer { win.isHidden = true }

            let navTitles = allLabelsText(in: host.view)
            XCTAssertTrue(navTitles.contains(expectedTitle), "\(label): 导航标题应为 \(expectedTitle)，实际：\(navTitles)")

            XCTAssertEqual(cv.numberOfSections, 2, "\(label): List 应包含顶部信息段与外链入口段")
            XCTAssertEqual(cv.numberOfItems(inSection: 0), 1, "\(label): 顶部信息段应有 1 个整卡单元")
            XCTAssertEqual(cv.numberOfItems(inSection: 1), 6, "\(label): 外链入口段应完整渲染全部 6 行")

            let headerCell = try XCTUnwrap(cv.cellForItem(at: IndexPath(item: 0, section: 0)), "\(label): 顶部信息单元格未实例化")
            XCTAssertGreaterThan(headerCell.frame.width, 0)
            XCTAssertGreaterThan(headerCell.frame.height, 80, "\(label): 顶部图标+标题+版本号+简介卡片高度异常偏小：\(headerCell.frame)")
            XCTAssertLessThanOrEqual(headerCell.frame.maxX, 393)

            for idx in 0 ..< 6 {
                let cell = try XCTUnwrap(cv.cellForItem(at: IndexPath(item: idx, section: 1)), "\(label): 第 \(idx) 个入口行未实例化")
                XCTAssertGreaterThan(cell.frame.width, 0)
                XCTAssertGreaterThanOrEqual(cell.frame.height, PPUI.Layout.rowMinHeight, "\(label): 第 \(idx) 行高度低于最小点击区")
                XCTAssertLessThanOrEqual(cell.frame.maxX, 393)
            }

            // 1.5× 大字号下 List 内容总高度必须大于标准字号（证明字体缩放真实生效、未压扁或固定死行高）。
            let (baseWin, _, baseCv) = try hostAboutScreen(
                bundle: bundle,
                preferredLanguages: langs,
                sizeCategory: .large
            )
            defer { baseWin.isHidden = true }
            XCTAssertGreaterThan(
                cv.contentSize.height,
                baseCv.contentSize.height,
                "\(label): 1.5× 大字号下内容总高度(\(cv.contentSize.height))应大于标准字号(\(baseCv.contentSize.height))"
            )
        }
    }
}
