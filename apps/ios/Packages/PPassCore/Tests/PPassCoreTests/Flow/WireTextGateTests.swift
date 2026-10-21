import Foundation
import XCTest
@testable import PPassCore

/// #1073 门禁：iOS 的控制流只认 `reason`，不许再按桌面发来的文案 key 判断。
/// 扫 `apps/ios/Packages/*/Sources` 与 `apps/ios/PPass` 下的全部 Swift：
///   - 读 `.msgKey`（线上字段只剩 v1 垫片用，模型本身在 `Proto/Messages.swift`，豁免）；
///   - 拿 `"err.…"` 字面量做比较（`contains` / `hasPrefix` / `hasSuffix` / `==` / `case`）。
/// 本机字典的查表（`DiagText.resolve("err.pair_expired")`、`PairNote.diagKey`）是显示，不是判断，不拦。
final class WireTextGateTests: XCTestCase {
    static let patterns: [(name: String, regex: NSRegularExpression)] = [
        ("reads msgKey", try! NSRegularExpression(pattern: #"\.msgKey\b"#)),
        ("compares an err. literal", try! NSRegularExpression(pattern: #"(contains|hasPrefix|hasSuffix)\(\s*"err\."#)),
        ("compares an err. literal", try! NSRegularExpression(pattern: #"[!=]=\s*"err\."#)),
        ("matches an err. literal", try! NSRegularExpression(pattern: #"case\s+(let\s+\w+\s+where\s+)?"err\."#)),
    ]
    static let exempt = ["apps/ios/Packages/PPassCore/Sources/PPassCore/Proto/Messages.swift"]

    static func violations(in source: String, path: String) -> [String] {
        var out: [String] = []
        for (n, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for p in patterns where p.regex.firstMatch(in: line, range: range) != nil {
                out.append("\(path):\(n + 1): \(p.name): \(trimmed)")
            }
        }
        return out
    }

    static func scannedFiles() throws -> [(path: String, url: URL)] {
        let root = try RepoFixtures.repoRoot()
        let fm = FileManager.default
        var files: [(String, URL)] = []
        let packages = root.appendingPathComponent("apps/ios/Packages")
        let sourceRoots = try fm.contentsOfDirectory(atPath: packages.path).map { packages.appendingPathComponent("\($0)/Sources") }
            + [root.appendingPathComponent("apps/ios/PPass")]
        for dir in sourceRoots where fm.fileExists(atPath: dir.path) {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                if !exempt.contains(rel) { files.append((rel, url)) }
            }
        }
        return files
    }

    func testNoControlFlowReadsDesktopTextKeys() throws {
        let files = try Self.scannedFiles()
        XCTAssertTrue(files.contains { $0.path.hasSuffix("Flow/DeliveryClassification.swift") }, "扫描范围必须包含 PPassCore 源码")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("Live/LivePairing.swift") }, "扫描范围必须包含 App 源码")
        var found: [String] = []
        for f in files { found += Self.violations(in: try String(contentsOf: f.url, encoding: .utf8), path: f.path) }
        XCTAssertEqual(found, [], "按桌面文案 key 判断的写法：\n" + found.joined(separator: "\n"))
    }

    /// 扫描器自测：旧写法每一种都抓得到；显示查表与注释不误伤。
    func testTheScannerCatchesTheOldShapes() {
        let bad = [
            #"if let key = rejected.msgKey, isPairingLostText(key) { return .pairingLost }"#,
            #"text.contains("err.not_paired") || text.contains("err.not_authorized")"#,
            #"if key == "err.not_paired" { }"#,
            #"guard msg != "err.unsupported" else { }"#,
            #"case "err.not_authorized": return .pairingLost"#,
            #"if s.hasPrefix("err.") { }"#,
        ]
        for line in bad { XCTAssertFalse(Self.violations(in: line, path: "x").isEmpty, line) }
        let fine = [
            #"case .expired: return "err.pair_expired""#,
            #"note: DiagText.resolve("err.pair_expired")"#,
            #"// text.contains("err.not_paired")"#,
        ]
        for line in fine { XCTAssertEqual(Self.violations(in: line, path: "x"), [], line) }
    }
}
