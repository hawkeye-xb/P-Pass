import Foundation
import XCTest
@testable import PPass

/// #1152：`PPASS_ROUTE` / `PPASS_PAIR_CODE` 只在 DEBUG 构建里生效。
/// 反证：去掉 `value` 里的 `guard enabled` ⇒ 非 DEBUG 那几条变红。
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

    /// 这两个键只许出现在门控函数里：别处再直接读，Release 包就又能被塞入口。
    func test_only_the_gate_reads_the_debug_keys() throws {
        let app = RepoPaths.root.appendingPathComponent("apps/ios/PPass")
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files where file.lastPathComponent != "DebugLaunchInput.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("\"PPASS_ROUTE\""), "\(file.lastPathComponent) reads PPASS_ROUTE directly")
            XCTAssertFalse(source.contains("\"PPASS_PAIR_CODE\""), "\(file.lastPathComponent) reads PPASS_PAIR_CODE directly")
        }
    }
}
