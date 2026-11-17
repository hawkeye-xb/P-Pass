import XCTest
@testable import PPass

/// 10-29：选范围页按照片权限档多说一句。10-30：没有照片权限时不给选择，不说「没有找到照片」。
/// #1811 起权限两态（产品口径）：完整授权 = 相册可自动备份；有限授权与拒绝统一成「相册未完整授权」，
/// 相册不进自动范围，文件夹照常，用户挑的几张只走「挑几张传」。
/// 反证：`BucketScreen.notice(for:)` 把 `.partial` 映射成旧的可选状态（`offersChoices` 为真），本条红。
final class BucketAccessNoticeTests: XCTestCase {
    func test_each_access_tier_has_its_own_notice() {
        XCTAssertEqual(BucketScreen.notice(for: .full), .none)
        XCTAssertEqual(BucketScreen.notice(for: .partial), .noAccess)
        XCTAssertEqual(BucketScreen.notice(for: .none), .noAccess)
    }

    /// 10-30（5a）：没有照片权限时不给时间档和「开始备份 / 保存」——一张都读不到，选了也没用。
    /// 反证：`offersChoices` 恒为 true（回到无权限也能点保存）本条红。
    func test_no_access_hides_the_choices() {
        XCTAssertTrue(BucketScreen.offersChoices(.none))
        XCTAssertFalse(BucketScreen.offersChoices(.noAccess))
    }

    /// 定稿文案中英都在（缺 key 时 bundle 返回占位值）。
    func test_copy_exists_in_both_languages() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "bucket_no_access_title": "Photos access is incomplete",
                "bucket_no_access_body": "Photos won't be backed up automatically. Back up folders only, or send selected photos.",
                "bucket_no_access_action": "Open Settings",
                "bucket_request_access_action": "Allow Access",
                "bucket_no_selection": "No sources selected.",
                "hero_mixed_album_incomplete": "Backing up folders · Photos access incomplete",
                "hero_adjust_scope_action": "Adjust scope",
                "welcome_scan": "Scan to connect to a computer",
            ],
            "zh-Hans": [
                "bucket_no_access_title": "相册未完整授权",
                "bucket_no_access_body": "相册不会自动备份。可以只备份文件夹，或先挑几张传。",
                "bucket_no_access_action": "去设置",
                "bucket_request_access_action": "允许访问",
                "bucket_no_selection": "未选择任何来源。",
                "hero_mixed_album_incomplete": "文件夹备份中 · 相册未完整授权",
                "hero_adjust_scope_action": "调整范围",
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
