import XCTest
@testable import PPass

/// 10-29：选范围页按照片权限档多说一句。部分授权：页顶说明只备份允许的那些；拒绝：说没有权限并给「去设置」，不说「没有找到照片」。
/// 反证：`BucketScreen.notice(for:)` 把 `.none` 映射成 `.none`（回到「没有找到照片」）本条红。
final class BucketAccessNoticeTests: XCTestCase {
    func test_each_access_tier_has_its_own_notice() {
        XCTAssertEqual(BucketScreen.notice(for: .full), .none)
        XCTAssertEqual(BucketScreen.notice(for: .partial), .partial)
        XCTAssertEqual(BucketScreen.notice(for: .none), .noAccess)
    }

    /// 定稿文案中英都在（缺 key 时 bundle 返回占位值）。
    func test_copy_exists_in_both_languages() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "bucket_partial_access_note": "You've allowed access to some photos only. Only those will be backed up.",
                "bucket_no_access_title": "No access to photos",
                "bucket_no_access_body": "P-Pass can't read your photos, so it can't back them up.",
                "bucket_no_access_action": "Open Settings",
                "welcome_scan": "Scan to connect",
            ],
            "zh-Hans": [
                "bucket_partial_access_note": "只授权了部分照片，只会备份你允许的那些。",
                "bucket_no_access_title": "没有照片访问权限",
                "bucket_no_access_body": "P-Pass 读不到照片，没法备份。",
                "bucket_no_access_action": "去设置",
            ],
        ]
        for (lang, keys) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (key, text) in keys {
                XCTAssertEqual(L.s(key, bundle: bundle), text, "\(lang) \(key)")
            }
        }
    }
}
