import XCTest
@testable import PPass

/// 10-29：选范围页按照片权限档多说一句。拒绝：说没有权限并给「去设置」，不说「没有找到照片」。
/// （#1272 起部分授权不再在页顶加说明，改为设置页开关下一行小字；`.partial` 档仍在，只是不配文案。）
/// 反证：`BucketScreen.notice(for:)` 把 `.none` 映射成 `.none`（回到「没有找到照片」）本条红。
final class BucketAccessNoticeTests: XCTestCase {
    func test_each_access_tier_has_its_own_notice() {
        XCTAssertEqual(BucketScreen.notice(for: .full), .none)
        XCTAssertEqual(BucketScreen.notice(for: .partial), .partial)
        XCTAssertEqual(BucketScreen.notice(for: .none), .noAccess)
    }

    /// 10-30（5a）：没有照片权限时不给时间档和「开始备份 / 保存」——一张都读不到，选了也没用。
    /// 反证：`offersChoices` 恒为 true（回到无权限也能点保存）本条红。
    func test_no_access_hides_the_choices() {
        XCTAssertTrue(BucketScreen.offersChoices(.none))
        XCTAssertTrue(BucketScreen.offersChoices(.partial))
        XCTAssertFalse(BucketScreen.offersChoices(.noAccess))
    }

    /// 定稿文案中英都在（缺 key 时 bundle 返回占位值）。
    func test_copy_exists_in_both_languages() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "bucket_no_access_title": "No photo access",
                "bucket_no_access_body": "P-Pass can't read photos on this phone, so it can't back them up.",
                "bucket_no_access_action": "Open Settings",
                "welcome_scan": "Scan to connect to a computer",
            ],
            "zh-Hans": [
                "bucket_no_access_title": "无照片访问权限",
                "bucket_no_access_body": "无法读取这台手机上的照片，没法备份。",
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
