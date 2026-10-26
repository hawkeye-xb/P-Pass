// #1152：iOS 日志脱敏与电脑端 / Android 同口径——跑 daemon / 桌面壳 / transport / Android 共用的同一份
// assets/privacy/redact-vectors.json（exact + keep 两段；export 段是导出件专用的路径规则，日志写入器不用）。
import Foundation
import XCTest
@testable import PPassCore

final class SharedRedactVectorsTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("assets/privacy/redact-vectors.json").path) {
            url.deleteLastPathComponent()
        }
        let file = url.appendingPathComponent("assets/privacy/redact-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func testSharedVectorsHoldSameFileAsTheOtherImplementations() throws {
        let v = try vectors()
        var n = 0
        for c in try XCTUnwrap(v["exact"] as? [[String: String]]) {
            let input = try XCTUnwrap(c["in"]), want = try XCTUnwrap(c["out"])
            XCTAssertEqual(SharedRedact.redact(input), want, "input: \(input)")
            XCTAssertEqual(SharedRedact.redact(want), want, "not idempotent: \(want)")
            n += 1
        }
        for keep in try XCTUnwrap(v["keep"] as? [String]) {
            XCTAssertEqual(SharedRedact.redact(keep), keep, "false positive")
            n += 1
        }
        XCTAssertGreaterThanOrEqual(n, 40, "vector file shrank to \(n) log cases")
    }

    func testIpLiteralsParseLikeRustCoreNet() {
        XCTAssertEqual(SharedRedact.parseIpv4("203.0.113.7"), [203, 0, 113, 7])
        XCTAssertNil(SharedRedact.parseIpv4("203.0.113.07"), "前导 0 Rust 不认")
        XCTAssertNil(SharedRedact.parseIpv4("256.1.1.1"))
        XCTAssertNil(SharedRedact.parseIpv4("1.2.3"))
        XCTAssertEqual(SharedRedact.parseIpv6("2001:db8::1"), [0x2001, 0xdb8, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(SharedRedact.parseIpv6("::ffff:203.0.113.7"), [0, 0, 0, 0, 0, 0xffff, 0xcb00, 0x7107])
        XCTAssertEqual(SharedRedact.parseIpv6("::"), [Int](repeating: 0, count: 8))
        XCTAssertNil(SharedRedact.parseIpv6("1:2:3:4:5:6:7::8"), ":: 至少代表一组")
        XCTAssertNil(SharedRedact.parseIpv6(":::"))
        XCTAssertNil(SharedRedact.parseIpv6("12345::1"))
        XCTAssertNil(SharedRedact.parseIpv6("1.2.3.4::1"), "v4 不能出现在 :: 之前")
    }
}
