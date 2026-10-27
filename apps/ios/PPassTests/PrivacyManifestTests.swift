import XCTest

/// #937：隐私清单必须真的进了 App bundle 根目录——源码里有文件不等于打进了包，
/// Apple 只认 bundle 里的那一份。声明内容是否覆盖用到的 API 由 tools/ios/check-privacy-manifest.py 守。
final class PrivacyManifestTests: XCTestCase {
    func testPrivacyManifestIsBundledAndDeclaresNoTracking() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "App bundle 里没有 PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let categories = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertEqual(Set(categories), [
            "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPICategorySystemBootTime",
            "NSPrivacyAccessedAPICategoryFileTimestamp",
        ])
    }
}
