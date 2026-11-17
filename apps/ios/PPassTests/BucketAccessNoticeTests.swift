import PPassCore
import XCTest
@testable import PPass

/// 10-29：选范围页按照片权限档多说一句。10-30：没有照片权限时不给选择，不说「没有找到照片」。
/// #1811 起权限两态（产品口径）：完整授权 = 相册可自动备份；有限授权与拒绝统一成「相册未完整授权」，
/// 相册不进自动范围，文件夹照常，用户挑的几张只走「挑几张传」。
/// 反证：`BucketScreen.notice(for:)` 把 `.partial` 映射成旧的可选状态，本条红。
final class BucketAccessNoticeTests: XCTestCase {
    func test_each_access_tier_has_its_own_notice() {
        XCTAssertEqual(BucketScreen.notice(for: .full), .none)
        XCTAssertEqual(BucketScreen.notice(for: .partial), .noAccess)
        XCTAssertEqual(BucketScreen.notice(for: .none), .noAccess)
    }

    /// #1811 评审：未完整授权时相册卡片只显示「保存过的相册」供取消，不显示新增相册；完整授权显示全部。
    /// 反证：`visibleAlbums` 改回「未完整授权一张都不显示」或「不筛直接全显示」，对应断言红。
    func test_incomplete_access_shows_only_saved_albums_for_cancellation() {
        let a = AlbumBucket(id: "a", name: "A", count: 3, isCameraAlbum: false)
        let b = AlbumBucket(id: "b", name: "B", count: 4, isCameraAlbum: false)
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], saved: ["a"], photoAccess: .partial).map(\.id), ["a"],
                       "有限授权：保存过的 a 仍显示（可取消），新增的 b 不显示")
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], saved: ["a"], photoAccess: .none).map(\.id), ["a"],
                       "拒绝授权：同样只给已保存的相册")
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], saved: ["a"], photoAccess: .full).map(\.id), ["a", "b"],
                       "完整授权：全部显示")
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], saved: nil, photoAccess: .partial).map(\.id), [],
                       "从未保存：未完整授权时没有任何相册可显示")
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
