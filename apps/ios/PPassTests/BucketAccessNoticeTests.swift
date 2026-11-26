import PPassCore
import SwiftUI
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

    /// #1961：来源卡外壳与勾选角标的视觉值必须来自设计 token（对齐 Android SourceCard / SelectBadge），
    /// 相册卡与文件夹行角标都真实套用同一组视觉 token。
    /// 反证：删掉 `SourceCardChrome` / `SelectBadge` 会编译失败；把 paper/linen、ink/border、2pt/1pt、
    /// 22pt、borderStrong 1.5 改成别的值，对应断言红。
    func test_source_card_chrome_and_badge_match_design_tokens() {
        let selectedCard = SourceCardChrome(selected: true)
        let unselectedCard = SourceCardChrome(selected: false)
        XCTAssertEqual(selectedCard.cornerRadius, 16)
        XCTAssertEqual(unselectedCard.cornerRadius, 16)
        XCTAssertEqual(selectedCard.backgroundColor, PPColor.paper, "选中卡 paper 底")
        XCTAssertEqual(unselectedCard.backgroundColor, PPColor.linen, "未选卡 linen 底")
        XCTAssertEqual(selectedCard.borderColor, PPColor.ink, "选中卡 ink 描边")
        XCTAssertEqual(unselectedCard.borderColor, PPColor.border, "未选卡 border 描边")
        XCTAssertEqual(selectedCard.borderLineWidth, 2, "选中卡 2pt 描边")
        XCTAssertEqual(unselectedCard.borderLineWidth, 1, "未选卡 1pt 描边")

        let on = SelectBadge(selected: true)
        let off = SelectBadge(selected: false)
        XCTAssertEqual(on.diameter, 22)
        XCTAssertEqual(off.diameter, 22)
        XCTAssertEqual(on.fillColor, PPColor.ink, "选中角标 ink 底")
        XCTAssertEqual(off.fillColor, PPColor.paperDim, "未选角标 paper-dim 底")
        XCTAssertEqual(off.unselectedBorderColor, PPColor.borderStrong, "未选角标 border-strong 圈")
        XCTAssertEqual(off.unselectedBorderWidth, 1.5, "未选角标 1.5pt 圈")
    }

    /// #2067：从未添加文件夹时页面完全不出现文件夹区块；添加过后按需展示紧凑分组。
    func test_folder_section_visibility_is_on_demand() {
        XCTAssertFalse(BucketScreen.showsFolderSection(folders: []), "未添加文件夹时不展示文件夹区块")
        let folder = FolderSourceInfo(id: "f1", displayName: "Cam", available: true, count: 5)
        XCTAssertTrue(BucketScreen.showsFolderSection(folders: [folder]), "已有文件夹时按需展示")
    }

    /// #2067：已选计数按相册权限档与可见性准确汇总，不把不可见或已移除来源虚算进去。
    func test_selected_counts_respect_access_tier_and_folder_ids() {
        let a = AlbumBucket(id: "a", name: "A", count: 3, isCameraAlbum: false)
        let b = AlbumBucket(id: "b", name: "B", count: 4, isCameraAlbum: false)
        let f1 = FolderSourceInfo(id: "f1", displayName: "Raw", available: true, count: 2)
        let f2 = FolderSourceInfo(id: "f2", displayName: "Lost", available: false, count: 0)
        let checked: Set<String> = ["a", "b", "missing-album", "folder:f1", "folder:stale"]

        let fullCounts = BucketScreen.selectedCounts(albums: [a, b], folders: [f1, f2], checked: checked, photoAccess: .full)
        XCTAssertEqual(fullCounts.albums, 2)
        XCTAssertEqual(fullCounts.folders, 1)

        let partialCounts = BucketScreen.selectedCounts(albums: [a, b], folders: [f1, f2], checked: ["a", "folder:f2"], photoAccess: .partial)
        XCTAssertEqual(partialCounts.albums, 1)
        XCTAssertEqual(partialCounts.folders, 1)

        let noneCounts = BucketScreen.selectedCounts(albums: [], folders: [f1], checked: ["a", "folder:f1"], photoAccess: .none)
        XCTAssertEqual(noneCounts.albums, 1, "无相册权限时已保存但不可见的相册仍保留在 checked 里随 onDone 提交，摘要必须一致")
        XCTAssertEqual(noneCounts.folders, 1)

        let noneEmptyCounts = BucketScreen.selectedCounts(albums: [], folders: [], checked: [], photoAccess: .none)
        XCTAssertEqual(noneEmptyCounts.albums, 0)
        XCTAssertEqual(noneEmptyCounts.folders, 0)
    }

    /// #2067：底部主按钮摘要在中英文、单复数、首次「开始备份」与编辑「保存」各组合下保持清晰自然。
    func test_action_button_title_formats_selected_summary_in_both_languages() throws {
        let zhBundle = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))
        let enBundle = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let zhLocale = Locale(identifier: "zh-Hans")
        let enLocale = Locale(identifier: "en")

        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: false, albumCount: 2, folderCount: 1, bundle: zhBundle, locale: zhLocale),
            "保存（已选 2 相册 · 1 文件夹）",
        )
        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: false, albumCount: 2, folderCount: 0, bundle: zhBundle, locale: zhLocale),
            "保存（已选 2 相册）",
        )
        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: true, albumCount: 0, folderCount: 1, bundle: zhBundle, locale: zhLocale),
            "开始备份（已选 1 文件夹）",
        )
        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: false, albumCount: 0, folderCount: 0, bundle: zhBundle, locale: zhLocale),
            "保存（未选来源）",
        )

        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: false, albumCount: 2, folderCount: 1, bundle: enBundle, locale: enLocale),
            "Save (2 albums · 1 folder)",
        )
        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: false, albumCount: 1, folderCount: 0, bundle: enBundle, locale: enLocale),
            "Save (1 album)",
        )
        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: true, albumCount: 0, folderCount: 2, bundle: enBundle, locale: enLocale),
            "Start backup (2 folders)",
        )
        XCTAssertEqual(
            BucketScreen.actionButtonTitle(firstTime: true, albumCount: 0, folderCount: 0, bundle: enBundle, locale: enLocale),
            "Start backup (none selected)",
        )
    }

    /// #1961 / #2067：未完整权限提示与新增范围区块文案在共享与 IOS 词表中双语齐全，
    /// 失效文件夹显性文案对齐「需要重新允许」/「Permission needed」。
    func test_shared_scope_copy_is_used_and_legacy_keys_are_gone() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "scope_album_no_access_title": "Photos access is incomplete",
                "scope_album_no_access_body": "P-Pass can’t read photos on this phone, so it can’t back them up.",
                "scope_album_no_access_action": "Allow access to photos",
                "auto_backup_blocked_action": "Open settings",
                "source_kind_album": "Album",
                "source_kind_folder": "Folder",
                "hero_mixed_album_incomplete": "Backing up folders · Photos access incomplete",
                "hero_adjust_scope_action": "Adjust scope",
                "welcome_scan": "Scan to connect to a computer",
                "scope_time_section": "Backup time",
                "scope_folders_section": "Folders",
                "folder_sources_status_wait": "Permission needed",
            ],
            "zh-Hans": [
                "scope_album_no_access_title": "相册未完整授权",
                "scope_album_no_access_body": "无法读取这台手机上的照片，没法备份。",
                "scope_album_no_access_action": "允许访问照片",
                "auto_backup_blocked_action": "去设置",
                "source_kind_album": "相册",
                "source_kind_folder": "文件夹",
                "hero_mixed_album_incomplete": "文件夹备份中 · 相册未完整授权",
                "hero_adjust_scope_action": "调整范围",
                "scope_time_section": "备份时间",
                "scope_folders_section": "文件夹",
                "folder_sources_status_wait": "需要重新允许",
            ],
        ]
        let legacyKeys = [
            "bucket_no_access_title", "bucket_no_access_body",
            "bucket_no_access_action", "bucket_request_access_action",
        ]
        for (lang, keys) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (key, text) in keys {
                XCTAssertEqual(L.s(key, bundle: bundle), text, "\(lang) \(key)")
            }
            for key in legacyKeys {
                let missing = "\u{1}"
                XCTAssertEqual(bundle.localizedString(forKey: key, value: missing, table: "IOS"), missing,
                               "\(lang) 旧词条 \(key) 必须已从 IOS.strings 删除")
                XCTAssertEqual(bundle.localizedString(forKey: key, value: missing, table: nil), missing,
                               "\(lang) 旧词条 \(key) 不能被任何表兜底命中")
            }
        }
    }
}
