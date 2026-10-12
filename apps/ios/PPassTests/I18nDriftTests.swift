import XCTest
@testable import PPass

/// #316：i18n 的第四个消费者——iOS 捆绑副本不许漂移（对位 Android
/// `DiagTextTest.bundled_assets_never_drift_from_repo_source`）。
///
/// 比的是**原始字符串**（不是解析后的 JSON 对象）：一侧是仓库源文件 `assets/i18n/<lang>.json`，
/// 另一侧是**构建出来的 App bundle 里**的 `i18n/<lang>.json`——比仓库里的副本更进一步，连
/// 「副本没被打进包」也会红。同步：`just ios-sync-i18n`。四个消费者的清单见 `DiagText`。
final class I18nDriftTests: XCTestCase {
    private var sourceDir: URL { RepoPaths.root.appendingPathComponent("assets/i18n") }

    func test_bundled_assets_never_drift_from_repo_source() throws {
        for lang in ["en", "zh"] {
            let source = try String(contentsOf: sourceDir.appendingPathComponent("\(lang).json"), encoding: .utf8)
            let url = try XCTUnwrap(Bundle.main.url(forResource: lang, withExtension: "json", subdirectory: "i18n"),
                                    "App bundle 里没有 i18n/\(lang).json——跑 just ios-sync-i18n 并重新生成工程")
            let bundled = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(source, bundled, "捆绑的 \(lang).json 与仓库源发生漂移——跑 just ios-sync-i18n")
        }
    }

    /// 源目录多出一种语言（比如加了 ja.json）而 iOS 没带上 ⇒ 红，不许静默少一种语言。
    func test_every_source_language_is_bundled() throws {
        let langs = try FileManager.default.contentsOfDirectory(atPath: sourceDir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertFalse(langs.isEmpty)
        for file in langs {
            let name = String(file.dropLast(".json".count))
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "i18n"),
                            "assets/i18n/\(file) 没有捆绑进 iOS——跑 just ios-sync-i18n")
        }
    }

    func test_resolver_fills_placeholders_and_returns_nil_for_unknown_keys() throws {
        let en = try XCTUnwrap(DiagText.bundledDictionary(language: "en-US"))
        XCTAssertEqual(DiagText.resolve(dictJSON: en, key: "diag.indexing", vars: ["progress": "42"]),
                       "Indexing the library… 42%")
        XCTAssertNil(DiagText.resolve(dictJSON: en, key: "no.such.key"))
        let zh = try XCTUnwrap(DiagText.bundledDictionary(language: "zh-Hans-CN"))
        XCTAssertNotEqual(zh, en, "zh 开头的语言应取 zh.json")
    }
}
