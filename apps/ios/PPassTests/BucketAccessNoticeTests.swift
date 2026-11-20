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

    /// #1811 评审不变量：checked 里不能有看不见、无法取消的相册。
    /// 完整授权显示全部；未完整授权只显示当前 checked（已保存 + 本次未保存勾选），保证都能取消；
    /// none 时 albums() 为空，卡片为空。
    /// 反证：`visibleAlbums` 只按 saved 过滤（本次勾选的 b 会消失）或不筛直接全显示，对应断言红。
    func test_visible_albums_follow_checked_invariant() {
        let a = AlbumBucket(id: "a", name: "A", count: 3, isCameraAlbum: false)
        let b = AlbumBucket(id: "b", name: "B", count: 4, isCameraAlbum: false)
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], checked: ["a"], photoAccess: .partial).map(\.id), ["a"],
                       "有限授权：checked 里的 a 仍显示（可取消），没勾的 b 不显示")
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], checked: ["a", "b"], photoAccess: .partial).map(\.id), ["a", "b"],
                       "full→partial：本次勾选（未保存）的 b 也保持可见、可取消")
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], checked: ["a"], photoAccess: .full).map(\.id), ["a", "b"],
                       "完整授权：全部显示")
        XCTAssertEqual(BucketScreen.visibleAlbums([], checked: ["a"], photoAccess: .none).map(\.id), [],
                       "拒绝授权且 albums() 为空：一张都展示不了（编辑态相册部分由刷新清空）")
    }

    /// 定稿文案中英都在（缺 key 时 bundle 返回占位值）。
    func test_copy_exists_in_both_languages() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "bucket_no_access_title": "Photos access is incomplete",
                "bucket_no_access_body": "Photos won't be backed up automatically. Back up folders only, or send selected photos.",
                "bucket_no_access_action": "Open Settings",
                "bucket_request_access_action": "Allow Access",
                "hero_mixed_album_incomplete": "Backing up folders · Photos access incomplete",
                "hero_adjust_scope_action": "Adjust scope",
                "welcome_scan": "Scan to connect to a computer",
            ],
            "zh-Hans": [
                "bucket_no_access_title": "相册未完整授权",
                "bucket_no_access_body": "相册不会自动备份。可以只备份文件夹，或先挑几张传。",
                "bucket_no_access_action": "去设置",
                "bucket_request_access_action": "允许访问",
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
