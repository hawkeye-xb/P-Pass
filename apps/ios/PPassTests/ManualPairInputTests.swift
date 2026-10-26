import Foundation
import XCTest

/// #1149：手输配对串的输入框关闭自动纠正与联想（`autocorrectionDisabled` 同时关掉输入法的预测栏），
/// 配对串不进键盘词库。反证：去掉 `ManualPairScreen` 输入框上的 `.autocorrectionDisabled()` ⇒ 变红。
final class ManualPairInputTests: XCTestCase {
    func test_manual_pair_field_disables_autocorrection_and_capitalization() throws {
        let url = RepoPaths.root.appendingPathComponent("apps/ios/PPass/Pairing/OnboardingFlow.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let screen = try XCTUnwrap(source.components(separatedBy: "struct ManualPairScreen").dropFirst().first)
        let field = try XCTUnwrap(screen.components(separatedBy: "accessibilityIdentifier(\"pairCodeField\")").first)
        XCTAssertTrue(field.contains(".autocorrectionDisabled()"), "no autocorrect / predictive suggestions on the pairing string")
        XCTAssertTrue(field.contains(".textInputAutocapitalization(.never)"))
    }
}
