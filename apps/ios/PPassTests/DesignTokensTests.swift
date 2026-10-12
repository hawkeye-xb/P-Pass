import SwiftUI
import UIKit
import XCTest
@testable import PPass

/// #344：iOS 设计 token 与 assets/design/tokens.json 同源。
///
/// 读的是**仓库里的源文件**（不是 bundle 里的副本），逐键对照生成物
/// `PPass/Design/Tokens.generated.swift`。改了 tokens.json 却没重新生成 ⇒ 本测试红。
/// 另一道门是 `tools/ios/gen-tokens.py --check`（逐字节），在 ci-ios 里跑。
final class DesignTokensTests: XCTestCase {
    private func section(_ path: String...) throws -> [String: String] {
        let url = RepoPaths.root.appendingPathComponent("assets/design/tokens.json")
        var node = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in path {
            node = try XCTUnwrap(node[key] as? [String: Any], "tokens.json 缺 \(path.joined(separator: "."))")
        }
        var out: [String: String] = [:]
        for (k, v) in node {
            let entry = try XCTUnwrap(v as? [String: Any], "\(k) 不是 {value: …}")
            out[k] = try XCTUnwrap(entry["value"] as? String, "\(k).value 不是字符串")
        }
        return out
    }

    /// 逐键比较，失败时只报漂了的那几个键（整本字典的 diff 不可读）。
    private func assertSame(_ generated: [String: String], _ source: [String: String], _ hint: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        for key in Set(generated.keys).union(source.keys).sorted() where generated[key] != source[key] {
            XCTFail("\(hint)：\(key) 源=\(source[key] ?? "（无）") 生成物=\(generated[key] ?? "（无）")", file: file, line: line)
        }
    }

    func testColorsMatchSource() throws {
        try assertSame(PPTokenSource.colors, section("color"), "颜色 token 漂移——跑 just ios-tokens 重新生成")
    }

    func testRadiiMatchSource() throws {
        try assertSame(PPTokenSource.radii, section("radius"), "圆角 token 漂移——跑 just ios-tokens 重新生成")
    }

    func testMobileSizesMatchSource() throws {
        try assertSame(PPTokenSource.mobileSizes, section("size", "mobile"), "手机尺寸 token 漂移——跑 just ios-tokens 重新生成")
    }

    func testFontsMatchSource() throws {
        try assertSame(PPTokenSource.fonts, section("font"), "字体 token 漂移——跑 just ios-tokens 重新生成")
    }

    /// 生成器本身：每个 Color 常量的 sRGB 分量与源字符串一致（防生成器写错进制或通道顺序）。
    func testGeneratedColorsDecodeToSourceValues() throws {
        XCTAssertEqual(Set(PPColor.all.keys), Set(PPTokenSource.colors.keys))
        for (key, raw) in PPTokenSource.colors {
            let want = try XCTUnwrap(Self.rgba(raw), "\(key) 的源值 \(raw) 解析不了")
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(PPColor.all[key]!).getRed(&r, green: &g, blue: &b, alpha: &a))
            for (got, exp) in zip([r, g, b, a], want) {
                XCTAssertEqual(Double(got), exp, accuracy: 0.002, "\(key) = \(raw)")
            }
        }
    }

    /// 手机规则（tokens.json rules）：正文 ≥17、点击区 ≥56。生成值若被改小，这里先红。
    func testMobileFloorsHold() {
        XCTAssertGreaterThanOrEqual(PPSize.bodyMin, 17)
        XCTAssertGreaterThanOrEqual(PPSize.tapMin, 56)
    }

    private static func rgba(_ s: String) -> [Double]? {
        if s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) {
            return [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1]
        }
        let inner = s.replacingOccurrences(of: "rgba(", with: "").replacingOccurrences(of: ")", with: "")
        let parts = inner.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        return [parts[0]! / 255, parts[1]! / 255, parts[2]! / 255, parts[3]!]
    }
}
