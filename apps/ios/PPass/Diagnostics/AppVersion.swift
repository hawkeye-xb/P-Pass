import Foundation

/// 本包的版本（#346）。version 相关值由构建阶段「Stamp version」（tools/ios/stamp-version.sh）写进 Info.plist：
/// - `short`：CFBundleShortVersionString，X.Y.Z（系统设置里看到的）
/// - `build`：CFBundleVersion，单调整数（对位 Android versionCode）
/// - `full`：PPassFullVersion，完整串（含 -test.N / -beta.N）——**判断「跑的是哪个二进制」看它**
/// - `buildStamp`：PPassBuildStamp，本地构建时间（#1820，见下）
struct AppVersion: Equatable {
    let short: String
    let build: String
    let full: String
    /// PPF_BUILD_VERSION 或 fallback（本地/非 tag 构建）。
    let source: String
    /// #1820：本地开发包的构建时间（`MM-DD HH:MM`，PPF_BUILD_STAMP 注入）；
    /// 正式/CI 构建没有这个值，是空串。
    let buildStamp: String

    static func from(_ info: [String: Any]) -> AppVersion {
        AppVersion(
            short: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            full: info["PPassFullVersion"] as? String ?? "",
            source: info["PPassVersionSource"] as? String ?? "",
            buildStamp: info["PPassBuildStamp"] as? String ?? ""
        )
    }

    static var current: AppVersion { from(Bundle.main.infoDictionary ?? [:]) }

    /// 诊断页显示的一行：完整串 + 构建号，例如「0.5.7-test.1 (5007001)」。
    /// #1820：本地开发包在后面追加构建时间「11-17 11:30」；正式/CI 包不追加。
    var displayLine: String {
        let base = "\(full.isEmpty ? short : full) (\(build))"
        let stamp = buildStamp.trimmingCharacters(in: .whitespaces)
        return stamp.isEmpty ? base : "\(base) \(stamp)"
    }
}
