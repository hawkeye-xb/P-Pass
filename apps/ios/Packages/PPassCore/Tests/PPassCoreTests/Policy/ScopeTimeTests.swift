// #1263：备份范围 = 相册 + 时间档（从今天起 / 全部）。范围仍只是查询条件：时间编进范围键，引擎对已落库的行也按它判断。
import XCTest
@testable import PPassCore

final class ScopeTimeTests: XCTestCase {
    private let utc8: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }()
    /// 2026-10-29 15:30 +08:00 → 当天零点 = 2026-10-28T16:00:00Z。
    private let now = Date(timeIntervalSince1970: 1_793_259_000)
    private let midnightMs: Int64 = 1_793_203_200_000

    // MARK: 「今天」从零点算，锚点落盘后不动

    func testFromTodayStartsAtLocalMidnightNotAtTheMomentOfSaving() {
        XCTAssertEqual(ScopePolicy.sinceForSave(previous: nil, wantsAll: false, now: now, calendar: utc8), .since(ms: midnightMs))
    }

    /// 编辑相册、时间档仍是「从今天起」：起点不往后挪（否则昨天还没传的会掉出范围）。反证：去掉 `previous` 分支，这里红。
    func testEditingKeepsTheExistingAnchor() {
        let later = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(ScopePolicy.sinceForSave(previous: .since(ms: midnightMs), wantsAll: false, now: later, calendar: utc8), .since(ms: midnightMs))
    }

    func testAllThenBackToTodayAnchorsAtThatDaysMidnight() {
        let later = now.addingTimeInterval(86_400)
        XCTAssertEqual(ScopePolicy.sinceForSave(previous: .all, wantsAll: false, now: later, calendar: utc8), .since(ms: midnightMs + 86_400_000))
        XCTAssertEqual(ScopePolicy.sinceForSave(previous: .since(ms: midnightMs), wantsAll: true, now: later, calendar: utc8), .all)
    }

    // MARK: 扩大走 SCOPE_ADDED，缩小不触发

    func testFromTodayToAllIsAWidening() {
        XCTAssertTrue(ScopePolicy.widened(previous: .since(ms: midnightMs), next: .all))
        XCTAssertTrue(ScopePolicy.widened(previous: .since(ms: midnightMs), next: .since(ms: midnightMs - 1)))
    }

    func testNarrowingOrUnchangedOrFirstSaveIsNotAWidening() {
        XCTAssertFalse(ScopePolicy.widened(previous: .all, next: .since(ms: midnightMs)), "缩小：不补扫，没传的从待办里消失")
        XCTAssertFalse(ScopePolicy.widened(previous: .all, next: .all))
        XCTAssertFalse(ScopePolicy.widened(previous: .since(ms: midnightMs), next: .since(ms: midnightMs)))
        XCTAssertFalse(ScopePolicy.widened(previous: nil, next: .all), "首次保存由「新增相册」触发，不重复算")
    }

    // MARK: inScope 加上时间条件

    func testKeyRoundTrips() {
        let key = ScopeKey.encode(albums: ["A/L0/001", "B/L0/040"], capturedAtMs: 42)
        XCTAssertEqual(ScopeKey.decode(key).albums, ["A/L0/001", "B/L0/040"])
        XCTAssertEqual(ScopeKey.decode(key).capturedAtMs, 42)
        XCTAssertNil(ScopeKey.decode(ScopeKey.encode(albums: ["A"], capturedAtMs: nil)).capturedAtMs)
    }

    func testFromTodayKeepsTodaysPhotosAndDropsOlderOnes() {
        let today = ScopeKey.encode(albums: ["recents"], capturedAtMs: midnightMs)
        let yesterday = ScopeKey.encode(albums: ["recents"], capturedAtMs: midnightMs - 1)
        let since = BackupSince.since(ms: midnightMs)
        XCTAssertTrue(ScopeKey.inScope(today, selected: ["recents"], since: since), "零点整拍的算今天")
        XCTAssertFalse(ScopeKey.inScope(yesterday, selected: ["recents"], since: since))
        XCTAssertTrue(ScopeKey.inScope(yesterday, selected: ["recents"], since: .all), "改成「全部」后以前的照片回到范围内")
    }

    func testAlbumConditionStillApplies() {
        let key = ScopeKey.encode(albums: ["wechat"], capturedAtMs: midnightMs + 1)
        XCTAssertFalse(ScopeKey.inScope(key, selected: ["recents"], since: .all))
        XCTAssertFalse(ScopeKey.inScope(key, selected: [], since: .since(ms: midnightMs)))
    }

    /// 拍摄时间未知、或 #1263 之前建的行（键里没有时间）：「从今天起」下算范围外，「全部」下照旧。
    func testKeyWithoutTimeIsOutsideFromToday() {
        let legacy = "recents" // 旧格式：只有相册
        XCTAssertFalse(ScopeKey.inScope(legacy, selected: ["recents"], since: .since(ms: midnightMs)))
        XCTAssertTrue(ScopeKey.inScope(legacy, selected: ["recents"], since: .all))
    }

    // MARK: 首次默认勾选「最近项目」

    func testFirstTimeDefaultsToTheCameraAlbum() {
        XCTAssertEqual(ScopePolicy.initialSelection(saved: nil, available: ["recents", "wechat"], cameraAlbum: "recents"), ["recents"])
    }

    func testSavedScopeIsShownAsIsAndNewAlbumsStayUnchecked() {
        XCTAssertEqual(ScopePolicy.initialSelection(saved: ["wechat", "gone"], available: ["recents", "wechat", "new"], cameraAlbum: "recents"), ["wechat"])
        XCTAssertEqual(ScopePolicy.initialSelection(saved: [], available: ["recents"], cameraAlbum: "recents"), [], "用户存过空集就是空集")
    }

    func testNoCameraAlbumFallsBackToNothingChecked() {
        XCTAssertEqual(ScopePolicy.initialSelection(saved: nil, available: ["wechat"], cameraAlbum: nil), [])
        XCTAssertEqual(ScopePolicy.initialSelection(saved: nil, available: ["wechat"], cameraAlbum: "recents"), [])
    }

    // MARK: 存储

    func testStorePersistsTheTimeChoicePerDesktop() throws {
        let tmp = TempDir()
        let store = BackupScopeStore(directory: tmp.url, daemonNodeId: "mac")
        XCTAssertNil(try store.since(), "从未保存")
        try store.saveScope(selected: ["recents"], allCurrent: ["recents"], since: .since(ms: midnightMs))
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").since(), .since(ms: midnightMs))
        try store.saveScope(selected: ["recents"], allCurrent: ["recents"], since: .all)
        XCTAssertEqual(try store.since(), .all)
        XCTAssertNil(try BackupScopeStore(directory: tmp.url, daemonNodeId: "win").since(), "按电脑各存一份")
    }

    /// #1263 之前保存的文件没有 since_ms：按「全部」读（老范围的语义不变）。
    func testOldFileWithoutTheFieldMeansAll() throws {
        let tmp = TempDir()
        tmp.write("backup_scope-mac.json", #"{"bucket_ids":["a"],"known_bucket_ids":["a"]}"#)
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").since(), .all)
    }

    // MARK: 首页后台备份卡

    func testBackgroundCardShowsUntilEnabledOrDismissed() throws {
        let tmp = TempDir()
        let prefs = BackgroundBackupCardPrefs(directory: tmp.url)
        XCTAssertFalse(prefs.dismissed())
        XCTAssertTrue(BackgroundBackupCardPrefs.shows(autoBackup: false, dismissed: prefs.dismissed()))
        XCTAssertFalse(BackgroundBackupCardPrefs.shows(autoBackup: true, dismissed: false), "开了就不再引导")
        try prefs.dismiss()
        XCTAssertTrue(BackgroundBackupCardPrefs(directory: tmp.url).dismissed())
        XCTAssertFalse(BackgroundBackupCardPrefs.shows(autoBackup: false, dismissed: true))
    }
}
