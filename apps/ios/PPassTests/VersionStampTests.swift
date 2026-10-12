import XCTest
@testable import PPass

/// #346：装进模拟器的这个包，版本号可判定。读的是**构建产物**的 Info.plist（Bundle.main），
/// 也就是「Stamp version」构建阶段真正写进去的值，不是源码里的占位。
final class VersionStampTests: XCTestCase {
    private let v = AppVersion.current

    func testShortVersionIsThreeNumericComponents() {
        XCTAssertNotNil(v.short.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression), "CFBundleShortVersionString=\(v.short)")
        XCTAssertNotEqual(v.short, "0.0.0", "还是 Info.plist 的占位——Stamp version 构建阶段没跑")
    }

    func testBuildNumberIsAPositiveInteger() {
        XCTAssertNotNil(v.build.range(of: #"^[1-9]\d*$"#, options: .regularExpression), "CFBundleVersion=\(v.build)")
    }

    func testFullVersionStartsWithShortVersion() {
        XCTAssertTrue(v.full == v.short || v.full.hasPrefix(v.short + "-"), "PPassFullVersion=\(v.full) short=\(v.short)")
        XCTAssertTrue(["PPF_BUILD_VERSION", "fallback"].contains(v.source), "PPassVersionSource=\(v.source)")
    }

    /// 构建号与完整串的换算规则（stamp-version.sh 头注释）在产物上成立。
    func testBuildNumberFollowsTheRule() throws {
        let m = try XCTUnwrap(v.full.wholeMatch(of: /(\d+)\.(\d+)\.(\d+)(?:-(test|beta)\.(\d+))?/), "PPassFullVersion=\(v.full)")
        let x = Int(m.1)!, y = Int(m.2)!, z = Int(m.3)!
        var s = 999
        if m.4 == "test" { s = Int(m.5!)! }
        if m.4 == "beta" { s = 500 + Int(m.5!)! }
        XCTAssertEqual(v.build, String(((x * 1000 + y) * 1000 + z) * 1000 + s))
    }

    /// 本地/非 tag 构建：完整串必须等于 Base.xcconfig 的 PPASS_FALLBACK_VERSION（回退值只有那一处）。
    func testFallbackComesFromXcconfig() throws {
        guard v.source == "fallback" else { throw XCTSkip("本次由 PPF_BUILD_VERSION 注入（\(v.full)），不走回退") }
        let xcconfig = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/Config/Base.xcconfig"), encoding: .utf8)
        let line = try XCTUnwrap(xcconfig.split(separator: "\n").first { $0.hasPrefix("PPASS_FALLBACK_VERSION") })
        let value = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(v.full, value)
    }
}
