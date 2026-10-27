import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PPass

/// #1152：诊断「复制」只写本机剪贴板并带过期时间。反证：去掉 `.localOnly` 或 `.expirationDate` ⇒ 红；
/// 诊断页改回 `UIPasteboard.general.string =` ⇒ 接线那条红。
final class DiagnosticsClipboardTests: XCTestCase {
    func test_payload_is_local_only_and_expires() {
        let now = Date(timeIntervalSince1970: 1_000)
        let p = DiagnosticsClipboard.payload(for: "version: 1", now: now)
        XCTAssertEqual(p.options[.localOnly] as? Bool, true)
        XCTAssertEqual(p.options[.expirationDate] as? Date, now.addingTimeInterval(DiagnosticsClipboard.lifetime))
        XCTAssertEqual(p.items.first?[UTType.utf8PlainText.identifier] as? String, "version: 1")
        XCTAssertGreaterThan(DiagnosticsClipboard.lifetime, 0)
        XCTAssertLessThanOrEqual(DiagnosticsClipboard.lifetime, 600)
    }

    func test_diagnostics_screen_copies_through_it_only() throws {
        let url = RepoPaths.root.appendingPathComponent("apps/ios/PPass/Diagnostics/DiagnosticsScreen.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("DiagnosticsClipboard.copy("))
        XCTAssertFalse(source.contains("UIPasteboard.general"))
    }
}
