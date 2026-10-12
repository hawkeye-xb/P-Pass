import Foundation

/// 把 diag 的 msg_key（注册表：crates/diag/src/keys.rs）解析成当前语言的人话（对位 Android `DiagText`）。
///
/// 字典的唯一真相源是仓库 `assets/i18n/{en,zh}.json`，**逐字节**捆绑进 App 的 `i18n/` 目录
/// （`just ios-sync-i18n`）。改源文件里一个 key 时，这四个消费者都要跟上，否则至少一条 lane 红：
///   1. `crates/diag/src/keys.rs` 的 `msg_keys!` 注册表（双向断言）+ `ALL.len()` 硬编码计数
///   2. 桌面壳 `apps/desktop/src/lib/i18n.js`（直接 import 源文件，无副本）
///   3. Android 逐字节副本 `apps/android/app/src/main/assets/i18n/`（`DiagTextTest.bundled_assets_never_drift_from_repo_source`）
///   4. 本 iOS 逐字节副本 `apps/ios/PPass/Resources/i18n/`（`I18nDriftTests.test_bundled_assets_never_drift_from_repo_source`，#316）
/// 占位符写法 `{name}`。
enum DiagText {
    /// 纯解析：key 不认识时返回 nil（调用方退回通用文案，绝不因服务端新 key 崩溃）。
    static func resolve(dictJSON: Data, key: String, vars: [String: String] = [:]) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: dictJSON) as? [String: Any],
              let raw = dict[key] as? String, !raw.isEmpty else { return nil }
        var s = raw
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    /// 按语言取捆绑字典：zh 开头用 zh.json，其余一律 en.json（与 Android 相同的判据）。
    static func bundledDictionary(language: String, bundle: Bundle = .main) -> Data? {
        let name = language.hasPrefix("zh") ? "zh" : "en"
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "i18n") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 用当前首选语言解析。
    static func resolve(_ key: String, vars: [String: String] = [:],
                        language: String = Locale.preferredLanguages.first ?? "en") -> String? {
        guard let data = bundledDictionary(language: language) else { return nil }
        return resolve(dictJSON: data, key: key, vars: vars)
    }
}
