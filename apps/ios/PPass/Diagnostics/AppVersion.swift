import Foundation

/// 本包的版本（#346）。三个值都由构建阶段「Stamp version」（tools/ios/stamp-version.sh）写进 Info.plist：
/// - `short`：CFBundleShortVersionString，X.Y.Z（系统设置里看到的）
/// - `build`：CFBundleVersion，单调整数（对位 Android versionCode）
/// - `full`：PPassFullVersion，完整串（含 -test.N / -beta.N）——**判断「跑的是哪个二进制」看它**
struct AppVersion: Equatable {
    let short: String
    let build: String
    let full: String
    /// PPF_BUILD_VERSION 或 fallback（本地/非 tag 构建）。
    let source: String

    static func from(_ info: [String: Any]) -> AppVersion {
        AppVersion(
            short: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            full: info["PPassFullVersion"] as? String ?? "",
            source: info["PPassVersionSource"] as? String ?? ""
        )
    }

    static var current: AppVersion { from(Bundle.main.infoDictionary ?? [:]) }

    /// 诊断页显示的一行：完整串 + 构建号，例如「0.5.7-test.1 (5007001)」。
    var displayLine: String { "\(full.isEmpty ? short : full) (\(build))" }
}
