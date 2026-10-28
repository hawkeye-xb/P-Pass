import Foundation
import XCTest
@testable import PPass

/// #1152 / #1227：全部 `PPASS_*` 调试入口只在 DEBUG 构建里生效。
/// 反证：去掉 `value` 里的 `guard enabled` ⇒ 非 DEBUG 那几条变红；在门控外直接读 `"PPASS_…"` ⇒ 源码扫描变红。
final class DebugLaunchInputTests: XCTestCase {
    private let suite = "debug-launch-input-tests"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func test_release_ignores_environment_and_user_defaults() {
        defaults.set("diagnostics", forKey: "PPASS_ROUTE")
        let env = ["PPASS_ROUTE": "settings", "PPASS_PAIR_CODE": "ppf://pair?node=x"]
        XCTAssertNil(DebugLaunchInput.value("PPASS_ROUTE", fromDefaults: true, enabled: false, environment: env, defaults: defaults))
        XCTAssertNil(DebugLaunchInput.value("PPASS_PAIR_CODE", enabled: false, environment: env, defaults: defaults))
        XCTAssertNil(DebugLaunchInput.value("PPASS_ROUTE", fromDefaults: true, enabled: false, environment: [:], defaults: defaults),
                     "UserDefaults 来源同样被挡")
    }

    func test_debug_reads_both_sources_environment_first() {
        defaults.set("diagnostics", forKey: "PPASS_ROUTE")
        XCTAssertEqual(DebugLaunchInput.value("PPASS_ROUTE", fromDefaults: true, enabled: true, environment: [:], defaults: defaults), "diagnostics")
        XCTAssertEqual(DebugLaunchInput.value("PPASS_ROUTE", fromDefaults: true, enabled: true, environment: ["PPASS_ROUTE": "settings"], defaults: defaults), "settings")
        XCTAssertNil(DebugLaunchInput.value("PPASS_PAIR_CODE", enabled: true, environment: ["PPASS_PAIR_CODE": ""], defaults: defaults), "空串当没传")
    }

    /// #1227：登记的每个键（env 与 UserDefaults 两个来源）在非 DEBUG 下都读不到。
    func test_release_ignores_every_gated_key() {
        for key in DebugLaunchInput.gatedKeys {
            defaults.set("1", forKey: key)
            XCTAssertNil(DebugLaunchInput.value(key, fromDefaults: true, enabled: false, environment: [key: "1"], defaults: defaults), key)
            XCTAssertNil(DebugLaunchInput.value(key, fromDefaults: true, enabled: false, environment: [:], defaults: defaults), "\(key) UserDefaults")
            XCTAssertEqual(DebugLaunchInput.value(key, fromDefaults: true, enabled: true, environment: [key: "1"], defaults: defaults), "1", "\(key) DEBUG 仍可用")
        }
    }

    /// 演示场景：Release 下 env / UserDefaults 都不能把包切成演示数据。
    func test_release_scenario_is_not_selectable() {
        defaults.set("trouble", forKey: "PPASS_SCENARIO")
        XCTAssertNil(DebugLaunchInput.value("PPASS_SCENARIO", fromDefaults: true, enabled: false, environment: ["PPASS_SCENARIO": "trouble"], defaults: defaults))
    }

    private static let literal = try! NSRegularExpression(pattern: "\"PPASS_[A-Z0-9_]*\"")

    private func swiftFiles(_ url: URL) -> [URL] {
        (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    private func literals(in source: String) -> [String] {
        Self.literal.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { String(source[Range($0.range, in: source)!]) }
    }

    /// 源码扫描门禁（#1152 起，#1227 扩到全部 `PPASS_*`）：App 源码和本地包的非测试源码里，
    /// `"PPASS_…"` 字面量只许出现在 DebugLaunchInput.swift（门控函数）和整文件包在 `#if DEBUG` 里的 `PPass/Debug/*.swift`。
    /// 别处再直接读环境变量 / UserDefaults，Release 包就又多一个可被外部塞的入口。
    func test_only_the_gate_reads_ppass_keys() throws {
        let ios = RepoPaths.root.appendingPathComponent("apps/ios")
        let appRoot = ios.appendingPathComponent("PPass")
        var files = swiftFiles(appRoot)
        let packages = ios.appendingPathComponent("Packages")
        files += swiftFiles(packages).filter { !$0.path.contains("/Tests/") && !$0.path.contains("/IntegrationHost/") && !$0.path.contains("/.build/") }
        XCTAssertGreaterThan(files.count, 50, "扫描范围不对")
        let debugDir = appRoot.appendingPathComponent("Debug").path + "/"
        for file in files where file.lastPathComponent != "DebugLaunchInput.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let hits = literals(in: source)
            guard !hits.isEmpty else { continue }
            if file.path.hasPrefix(debugDir) {
                let lines = source.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                XCTAssertEqual(lines.first, "#if DEBUG", "\(file.lastPathComponent) 读 \(hits) 但整文件没包在 #if DEBUG 里")
                XCTAssertEqual(lines.last, "#endif", "\(file.lastPathComponent) 读 \(hits) 但整文件没包在 #if DEBUG 里")
            } else {
                XCTFail("\(file.lastPathComponent) 直接读 \(hits)——走 DebugLaunchInput（仅 DEBUG）")
            }
        }
    }

    /// 门控文件自己：每个字面量都登记在 gatedKeys，且只有 `value` 这一处碰环境变量 / UserDefaults。
    func test_gate_file_registers_every_key_and_reads_only_in_value() throws {
        let file = RepoPaths.root.appendingPathComponent("apps/ios/PPass/App/DebugLaunchInput.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let body = source.components(separatedBy: "static let gatedKeys").last!.components(separatedBy: "static var route").first!
        let registered = Set(literals(in: body))
        let used = Set(literals(in: source))
        XCTAssertEqual(used, registered, "DebugLaunchInput 里的键必须都登记进 gatedKeys，反之亦然")
        XCTAssertEqual(registered.count, DebugLaunchInput.gatedKeys.count)
        XCTAssertEqual(source.components(separatedBy: "processInfo.environment").count - 1, 1, "环境变量只许在 value 的默认参数里读")
        XCTAssertEqual(source.components(separatedBy: "defaults.string(forKey").count - 1, 1, "UserDefaults 只许在 value 里读")
    }
}
