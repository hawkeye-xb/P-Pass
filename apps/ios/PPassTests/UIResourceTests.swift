import SwiftUI
import UIKit
import XCTest
@testable import PPass

/// 界面资源的契约：字体按 PostScript 名都能取到；源码里用到的每个文案 key 中英两份都在；复数可用。
final class UIResourceTests: XCTestCase {
    /// 6 个字体都注册上了（prepare-fonts.py 改名后不再撞名；撞名时只会剩一个）。
    func testBrandFacesResolveByPostScriptName() {
        for face in PPFont.faces {
            XCTAssertNotNil(UIFont(name: face, size: 17), "字体 \(face) 没注册上（UIAppFonts / 文件名 / PostScript 名）")
        }
    }

    /// 扫 App 源码里所有 `L.s("…")` / `L.f("…"` / `L.p("…"` 的字面 key，中英两份必须都有（缺了界面会显示 key 本身）。
    func testEveryKeyUsedInSourcesExistsInBothLanguages() throws {
        let src = RepoPaths.root.appendingPathComponent("apps/ios/PPass")
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"L\.[sfp]\("([a-z0-9_]+)""#)
        var keys = Set<String>()
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        XCTAssertGreaterThan(keys.count, 50)
        for lang in ["en", "zh-Hans"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in keys.sorted() {
                let ios = bundle.localizedString(forKey: key, value: "\u{1}", table: "IOS")
                let shared = bundle.localizedString(forKey: key, value: "\u{1}", table: nil)
                XCTAssertTrue(ios != "\u{1}" || shared != "\u{1}", "\(lang) 缺文案 \(key)")
            }
        }
    }

    /// 走 App 真用的那条路（L.p → Bundle.main + stringsdict）。
    func testPluralsFromStringsdict() throws {
        switch Bundle.main.preferredLocalizations.first {
        case "en":
            XCTAssertEqual(L.p("state_pending", 1), "1 photo still to back up")
            XCTAssertEqual(L.p("state_pending", 54), "54 photos still to back up")
        case "zh-Hans":
            XCTAssertEqual(L.p("state_pending", 1), "还有 1 张待备份")
            XCTAssertEqual(L.p("state_pending", 54), "还有 54 张待备份")
        case let other:
            XCTFail("App 只有 en / zh-Hans 两种界面语言，实际选了 \(other ?? "nil")")
        }
    }

    /// iOS 覆盖层真的盖住了 Android 说法（iOS 点通知只打开 App，指路要写 iOS 设置项的名字，不能说「点开后在系统设置中允许」）。
    func testIOSOverlayWinsOverAndroidWording() throws {
        let zh = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(zh.localizedString(forKey: "notif_media_none_body", value: nil, table: "IOS"),
                       "照片权限已关闭，备份已停止。在「设置 › P-Pass › 照片」允许访问。")
        XCTAssertEqual(zh.localizedString(forKey: "notif_media_none_body", value: nil, table: nil),
                       "照片权限已关闭，备份已停止。点开后在系统设置中允许访问。")
    }

    /// 10-29 文案 B12：iOS 首页不再有 idle_auto_hint 状态行，覆盖层里也不留这两条（留着会让人以为还在用）。
    func testIdleAutoHintIsNotOverriddenOnIOS() throws {
        for lang in ["zh-Hans", "en"] {
            let b = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in ["idle_auto_hint", "idle_auto_hint_any_network"] {
                XCTAssertEqual(b.localizedString(forKey: key, value: "\u{1}", table: "IOS"), "\u{1}", "\(lang) / \(key)")
            }
        }
    }
}
