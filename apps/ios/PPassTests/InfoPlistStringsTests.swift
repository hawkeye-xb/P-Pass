import XCTest
@testable import PPass

/// #1013：系统权限弹窗的说明，每种语言都要有，且与 Info.plist 里声明的 *UsageDescription 一一对应。
/// 新增一条权限说明却漏了某个语言的 InfoPlist.strings，系统弹窗就会回退成英文原文——本条红。
final class InfoPlistStringsTests: XCTestCase {
    func test_every_usage_description_is_localized_in_every_language() throws {
        let keys = (Bundle.main.infoDictionary ?? [:]).keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        XCTAssertFalse(keys.isEmpty)
        for lang in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"), "缺 \(lang).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}", table: "InfoPlist")
                XCTAssertNotEqual(value, "\u{0}", "\(lang).lproj/InfoPlist.strings 缺 \(key)")
                XCTAssertFalse(value.isEmpty, "\(lang) 的 \(key) 是空串")
            }
        }
    }

    /// #1259（10-29 改决定）：照片权限不加说明屏，说明就写在系统框的用途说明里。
    func test_photo_library_usage_description_says_why_full_access() throws {
        let expected = ["en": "Automatic backup needs access to all photos.", "zh-Hans": "自动备份新照片需要访问全部照片。"]
        for (lang, text) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "NSPhotoLibraryUsageDescription", value: nil, table: "InfoPlist"), text)
        }
    }

    /// 扫码页的本地网络前置说明（iOS 独有文案）两种语言都在。
    func test_scan_local_network_note_exists_in_every_language() throws {
        for lang in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["scan_local_network_note", "background_refresh_off_notice", "background_refresh_restricted_notice"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "\u{0}", table: "IOS"), "\u{0}", "\(lang) 缺 \(key)")
            }
        }
    }
}
