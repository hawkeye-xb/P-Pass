// #343（IOS-17）：「iOS 不承诺什么」的状态模型 + 文案红线（对着仓库 assets/i18n 真读）。
import Foundation
import XCTest
@testable import PPassCore

final class BackupPromiseTests: XCTestCase {

    private func dictionary(_ lang: String) throws -> [String: String] {
        let url = try RepoFixtures.repoRoot().appendingPathComponent("assets/i18n/\(lang).json")
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func keys(_ view: EngineView = EngineView(), refresh: BackgroundRefreshAvailability = .available, last: Date? = nil) -> [String] {
        BackupPromise.notices(view: view, backgroundRefresh: refresh, lastConfirmedAt: last, formatTime: { _ in "T" }).map(\.key)
    }

    /// 验收 1（模型一半）：首页常驻「打开 P-Pass 时备份」，排在最前。
    func testTheWhileOpenStatementIsAlwaysFirst() {
        XCTAssertEqual(keys(), [BackupPromise.whileOpenTitle, BackupPromise.whileOpenBody])
        XCTAssertEqual(Array(keys(EngineView(state: .running)).prefix(2)), [BackupPromise.whileOpenTitle, BackupPromise.whileOpenBody])
    }

    /// 后台 App 刷新关了 / 被限制：如实说「只在打开时备份」；可用时不多说。
    func testBackgroundRefreshAvailabilityIsStatedHonestly() {
        XCTAssertFalse(keys(refresh: .available).contains(BackupPromise.refreshOff))
        XCTAssertTrue(keys(refresh: .denied).contains(BackupPromise.refreshOff))
        XCTAssertTrue(keys(refresh: .restricted).contains(BackupPromise.refreshRestricted))
    }

    /// iOS 特有的三个等待原因各有一句人话；共有的等待原因不在这里重复。
    func testIOSOnlyWaitReasonsMapToTheirOwnNotice() {
        func waiting(_ r: WaitReason) -> [String] { keys(EngineView(state: .waiting, waitReason: r)) }
        XCTAssertTrue(waiting(.executionBlocked).contains(BackupPromise.waitOpenApp))
        XCTAssertTrue(waiting(.originalUnavailable).contains(BackupPromise.waitICloudOriginal))
        XCTAssertTrue(waiting(.localStorageFull).contains(BackupPromise.waitPhoneStorageFull))
        XCTAssertEqual(waiting(.wifi).count, 2)
    }

    /// 最近一次成功（#340 评论：后台没跑时用户自己能发现）。
    func testTheLastSuccessIsShownWhenKnown() {
        let n = BackupPromise.notices(view: EngineView(), backgroundRefresh: .available, lastConfirmedAt: Date(), formatTime: { _ in "昨天 21:30" })
        XCTAssertEqual(n.last, PromiseNotice(BackupPromise.lastBackup, vars: ["time": "昨天 21:30"]))
    }

    /// 验收 4（E1 一半）：模型能产出的每个 key 在中英两份字典里都有、非空。
    func testEveryKeyIsInBothDictionaries() throws {
        for lang in ["zh", "en"] {
            let d = try dictionary(lang)
            for key in BackupPromise.allKeys {
                XCTAssertFalse((d[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(lang).json 缺 \(key)")
            }
        }
    }

    /// 验收 2：本卡新增的文案里不出现任何数字（频率 / 滞后 / 时长），中文数字也算。
    /// 反证：在任一条里写进「每晚」之外的「6 小时」之类 → 红。
    func testNoUnmeasuredNumbersInTheNewCopy() throws {
        let digits = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "一二三四五六七八九十百千万两半"))
        for lang in ["zh", "en"] {
            let d = try dictionary(lang)
            for key in BackupPromise.allKeys where key.hasPrefix("ui.ios_") {
                let text = d[key] ?? ""
                XCTAssertNil(text.rangeOfCharacter(from: digits), "\(lang) \(key) 含数字：\(text)")
            }
        }
    }

    /// 验收 1 / 3：不用「自动备份」的措辞，不提 Android 才有的电池白名单 / 开机自启 / 启动管理。
    func testNoMisleadingOrAndroidOnlyWording() throws {
        let banned = ["自动备份", "电池", "白名单", "开机", "自启", "启动管理", "automatic backup", "auto-backup", "battery", "whitelist", "autostart", "boot"]
        for lang in ["zh", "en"] {
            let d = try dictionary(lang)
            for key in BackupPromise.allKeys where key.hasPrefix("ui.ios_") {
                let text = (d[key] ?? "").lowercased()
                for word in banned { XCTAssertFalse(text.contains(word.lowercased()), "\(lang) \(key) 含「\(word)」") }
            }
        }
    }
}
