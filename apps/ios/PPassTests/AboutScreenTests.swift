@testable import PPass
import SwiftUI
import XCTest

@MainActor
final class AboutScreenTests: XCTestCase {
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

    func testAboutScreenHostingUnderLargeTextDoesNotCollapse() {
        let host = UIHostingController(
            rootView: NavigationStack { AboutScreen() }
                .environment(\.sizeCategory, .accessibilityExtraLarge)
        )
        host.additionalSafeAreaInsets = .zero
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }
}
