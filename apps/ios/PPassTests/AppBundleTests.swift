import XCTest

/// #887：宿主 App 能被装进模拟器、测试 bundle 能注入并读到它的 Info.plist。
/// 这是脚手架的冒烟测试——测的是「工程能构建、能跑测试」，不是业务行为。
final class AppBundleTests: XCTestCase {
    func testHostAppBundleIsLoaded() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "PPass")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "P-Pass")
        let bundleId = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertFalse(bundleId.isEmpty)
        XCTAssertFalse(bundleId.hasSuffix(".tests"), "Bundle.main 应是宿主 App，不是测试 bundle")
    }
}
