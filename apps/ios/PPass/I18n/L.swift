import Foundation

/// 界面文案（#315）。两张表：
/// - `IOS.strings`：手写，只放 iOS 独有或 Android 说法在 iOS 上不成立的句子（先查这张）。
/// - `Localizable.strings` / `.stringsdict`：由 tools/ios/gen-strings.py 从 Android strings.xml 生成，
///   key 与 Android 完全一致——两端说同一句话。
/// diag/err 的 msg_key 不走这里，走 `DiagText`（assets/i18n 的逐字节副本）。
enum L {
    private static let missing = "\u{1}__missing__"

    static func s(_ key: String, bundle: Bundle = .main) -> String {
        let ios = bundle.localizedString(forKey: key, value: missing, table: "IOS")
        if ios != missing { return ios }
        let shared = bundle.localizedString(forKey: key, value: missing, table: nil)
        if shared != missing { return shared }
        assertionFailure("缺文案 key：\(key)")
        return key
    }

    /// 带参数：`%1$@` / `%1$ld`（生成器已把 Android 的 %1$s / %1$d 换成 iOS 写法）。
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: s(key), locale: Locale.current, arguments: args)
    }

    /// 复数（stringsdict）：第一个参数是数量。
    static func p(_ key: String, _ count: Int, _ more: CVarArg...) -> String {
        String(format: s(key), locale: Locale.current, arguments: [count] + more)
    }
}
