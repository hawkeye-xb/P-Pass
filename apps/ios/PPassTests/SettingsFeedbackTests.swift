@testable import PPassCore
import UIKit
import XCTest
@testable import PPass

/// #971 设置写盘失败回到真实值并提示 / #972 用户命令出错有反馈 / #982 关「仅 Wi‑Fi」先确认、后台备份默认关。
/// 引擎与相册换成可注入失败的替身，AppModel 是真的。
@MainActor
final class SettingsFeedbackTests: XCTestCase {
    private struct Boom: Error {}

    /// 「盘」：写失败时不动，读永远是盘上的值。
    private final class StubEngine: BackupEngine {
        var disk = (wifi: true, auto: false, notify: true)
        var failWrites = false
        var failCommands = false
        var cancelResult: Int?
        var calls: [String] = []

        func facts() -> FlowFacts { FlowFacts() }
        func observe(_ onChange: @escaping () -> Void) {}
        func pauseOrResume() async {}
        func wake() async { calls.append("wake") }
        func retryFailed() async throws { calls.append("retry"); if failCommands { throw Boom() } }
        func remainingSnapshot() async throws -> RemainingSnapshot { calls.append("snapshot"); throw Boom() }
        func cancelRemaining(_ snapshot: RemainingSnapshot) async throws -> Int? { calls.append("cancel"); if failCommands { throw Boom() }; return cancelResult }
        func restoreSkipped() async throws { calls.append("restore"); if failCommands { throw Boom() } }
        func acknowledgeMissingSource() {}
        func notifyOnFailure() -> Bool { disk.notify }
        func setNotifyOnFailure(_ on: Bool) throws { calls.append("notify=\(on)"); if failWrites { throw Boom() }; disk.notify = on }
        func notificationAuthorization() async -> NotificationAuthorization { .authorized }
        func requestNotificationAuthorization() async -> NotificationAuthorization { .authorized }
        @MainActor func openNotificationSettings() {}
        var failOnboarded = false
        func finishOnboarding() throws { calls.append("onboarded"); if failOnboarded { throw Boom() } }
        func wifiOnly() -> Bool { disk.wifi }
        func setWifiOnly(_ on: Bool) throws { calls.append("wifi=\(on)"); if failWrites { throw Boom() }; disk.wifi = on }
        /// 设了就走真盘：与 `LiveEngineAdapter.setAutoBackup` 同一个写盘函数，写失败来自真实的只读目录（#1039）。
        var prefs: AutoBackupPrefs?
        func autoBackup() -> Bool { prefs?.enabled() ?? disk.auto }
        func setAutoBackup(_ on: Bool) throws {
            calls.append("auto=\(on)")
            if let prefs { try prefs.setUserChoice(on); return }
            if failWrites { throw Boom() }; disk.auto = on
        }
        var cardDismissed = false
        func backgroundCardDismissed() -> Bool { cardDismissed }
        func dismissBackgroundCard() throws { calls.append("card-dismissed"); if failWrites { throw Boom() }; cardDismissed = true }
        var refresh: BackgroundRefreshAvailability = .available
        func backgroundRefresh() -> BackgroundRefreshAvailability { refresh }
    }

    private final class StubMedia: MediaLibrary {
        var disk: Set<String>? = ["a"]
        var failSave = false
        var failRead = false
        /// nil = 系统还没问过；问过之后是用户在系统框里的选择。
        var granted: MediaAccess? = .full
        var answer: MediaAccess = .full
        var requested = 0
        func access() -> MediaAccess { granted ?? .none }
        func requestAccess() async -> MediaAccess { requested += 1; granted = answer; return answer }
        func albums() async throws -> [AlbumBucket] { [] }
        func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage? { nil }
        func savedScope() throws -> Set<String>? { if failRead { throw Boom() }; return disk }
        var since: BackupSince? = .all
        func savedSince() throws -> BackupSince? { if failRead { throw Boom() }; return disk == nil ? nil : since }
        func knownAlbums() -> Set<String> { [] }
        func existingAlbumIds() async -> Set<String>? { ["a", "b"] }
        func saveScope(_ selected: Set<String>, known: Set<String>, since: BackupSince) async throws {
            if failSave { throw Boom() }; disk = selected; self.since = since
        }
    }

    private func make() -> (AppModel, StubEngine, StubMedia) {
        let engine = StubEngine(), media = StubMedia()
        let fake = FakeBackend.make(.normal)
        let backend = Backend(isDemo: true, timeline: fake.timeline, live: fake.live, media: media, pairing: fake.pairing, engine: engine)
        return (AppModel(backend: backend), engine, media)
    }

    /// 等主 actor 上排队的 Task 跑完。
    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 50_000_000) }

    // MARK: 后台刷新告示（f57a2942 误删，对位 Android NoticeHost BACKUP_INTERRUPTED）

    /// 用户要后台备份、后台刷新被关 → 两页都显示告示、带「去处理」；被限制 → 显示但不给按钮。
    /// 反证：把 `refresh()` 里给 backgroundNotice 赋值那行删掉，或去掉 backgroundRequested 守卫，本组红。
    func test_background_refresh_notice_follows_the_fact_and_the_users_choice() {
        let (app, engine, _) = make()
        engine.disk.auto = true
        engine.refresh = .denied
        app.refresh()
        XCTAssertEqual(app.backgroundNotice?.canResolve, true)
        XCTAssertEqual(app.backgroundNotice?.body, L.s("background_refresh_off_notice"))

        engine.refresh = .restricted
        app.refresh()
        XCTAssertEqual(app.backgroundNotice?.canResolve, false, "被限制时用户改不了，不给按钮")
        XCTAssertEqual(app.backgroundNotice?.body, L.s("background_refresh_restricted_notice"))

        engine.disk.auto = false
        app.refresh()
        XCTAssertNil(app.backgroundNotice, "用户没要后台备份：后台刷新关不关与他无关，不打扰")

        engine.disk.auto = true
        engine.refresh = .available
        app.refresh()
        XCTAssertNil(app.backgroundNotice, "后台刷新恢复 → 告示消失")
    }

    // MARK: #1019

    /// 首次选范围点「开始备份」= 走完 onboarding（#1263 没有完成页）：保存范围后记「连过这台电脑」、后台备份写「关」、唤醒引擎、直接进首页。
    /// 反证：去掉 `finishFirstScope` 的调用，onboarded 不出现、phase 停在 chooseAlbums，本条红。
    private func chooseFirstScope(_ app: AppModel, wantsAll: Bool = false) {
        app.albumsChosen(["a", "b"], known: ["a", "b"], wantsAll: wantsAll, firstTime: true)
    }

    func test_first_scope_saves_marks_the_desktop_and_enters_home() async {
        let (app, engine, media) = make()
        media.disk = nil // 从未保存
        app.phase = .chooseAlbums
        chooseFirstScope(app)
        await settle()
        XCTAssertEqual(media.disk, ["a", "b"])
        XCTAssertEqual(engine.calls.prefix(2), ["onboarded", "auto=false"], "先记连过，后台备份默认关")
        XCTAssertTrue(engine.calls.contains("wake"), "新增相册 → SCOPE_ADDED")
        XCTAssertFalse(engine.calls.contains("auto=true"), "onboarding 不再问后台备份")
        XCTAssertEqual(app.phase, .main, "没有完成页")
        if case .since = media.since {} else { XCTFail("首次默认「从今天起」，实际 \(String(describing: media.since))") }
    }

    /// 记不下来：照样进首页（后果只是下次重连仍走首次设置），但要提示用户，不静默。
    func test_failed_onboarded_mark_still_enters_home_and_tells_the_user() async {
        let (app, engine, _) = make()
        engine.failOnboarded = true
        chooseFirstScope(app)
        await settle()
        XCTAssertEqual(app.phase, .main)
        XCTAssertEqual(app.notice?.message, L.s("setting_save_failed"))
    }

    // MARK: #1259 照片权限：不加说明屏（10-29 改决定）

    /// 首次配对、系统还没问过照片权限 → 直接进选范围页，系统框由选范围页读相册时弹（说明写在 NSPhotoLibraryUsageDescription）。
    /// 配对这一步自己不弹框，也不经过中间屏。
    func test_first_pairing_goes_straight_to_the_scope_page() {
        let (app, _, media) = make()
        media.granted = nil
        app.paired(firstTime: true, settingSaveFailed: false)
        XCTAssertEqual(app.phase, .chooseAlbums)
        XCTAssertEqual(media.requested, 0)
    }

    /// 连回以前连过的电脑直接进首页，不管照片权限问没问过。
    func test_known_desktop_goes_home() {
        let (known, _, media) = make()
        media.granted = nil
        known.paired(firstTime: false, settingSaveFailed: false)
        XCTAssertEqual(known.phase, .main)
    }

    /// 系统框里只给了部分 / 拒绝：照常走完选范围进首页，首页按三档权限出兜底卡（投影见 HomeProjectionTests 的 accessBlocked）。
    func test_partial_or_denied_access_lands_home_with_that_tier() async {
        for answer in [MediaAccess.partial, .none] {
            let (app, _, media) = make()
            media.granted = nil
            media.answer = answer
            app.paired(firstTime: true, settingSaveFailed: false)
            _ = await media.requestAccess() // 选范围页读相册时弹的那一次
            app.albumsChosen([], known: [], wantsAll: false, firstTime: true)
            await settle()
            XCTAssertEqual(app.phase, .main, "\(answer)")
            XCTAssertEqual(app.access, answer, "首页要拿到系统框之后的权限档")
        }
    }

    /// 10-29：选范围页读相册时可能刚弹过系统框，`refreshAccess` 让页面按弹框之后的那一档显示（部分 → 页顶说明，拒绝 → 去设置）。
    func test_refresh_access_picks_up_the_answer_from_the_prompt() async {
        let (app, _, media) = make()
        media.granted = nil
        app.paired(firstTime: true, settingSaveFailed: false)
        XCTAssertEqual(app.access, .none)
        media.answer = .partial
        _ = await media.requestAccess()
        app.refreshAccess()
        XCTAssertEqual(app.access, .partial)
        XCTAssertEqual(BucketScreen.notice(for: app.access), .partial)
    }

    // MARK: #1039 换新电脑清旧的后台备份意图写失败（对位 Android）

    /// 配对结局带着「清意图没写下来」：照常进选相册，并提示。反证：去掉 `paired` 里设 notice 那段，本条红。
    func test_new_desktop_intent_clear_failure_still_goes_on_and_tells_the_user() {
        let (app, _, _) = make()
        app.paired(firstTime: true, settingSaveFailed: true)
        XCTAssertEqual(app.phase, .chooseAlbums, "不拦配对")
        XCTAssertEqual(app.notice?.message, L.s("setting_save_failed"))

        let (ok, _, _) = make()
        ok.paired(firstTime: true, settingSaveFailed: false)
        XCTAssertNil(ok.notice, "写成了不打扰")
    }

    /// 偏好目录：盘上留着旧电脑的意图（requested=true，生产者已停）。
    private func leftoverIntent() throws -> (AppModel, AutoBackupPrefs, URL) {
        let prefsDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefsDir.path)
            try? FileManager.default.removeItem(at: prefsDir)
        }
        let prefs = AutoBackupPrefs(directory: prefsDir)
        try prefs.set(requested: true, enabled: false)
        let (app, engine, _) = make()
        engine.prefs = prefs
        return (app, prefs, prefsDir)
    }

    /// 首次选完范围：把意图写成「不开」，盘上 requested=false、enabled=false（#1039 的写入在 #1263 去掉完成页后保留）。
    /// 反证：去掉 `finishFirstScope` 里的 `setAutoBackup(false)`，盘上仍是旧意图，本条红。
    func test_finishing_without_background_backup_writes_not_requested_to_disk() async throws {
        let (app, prefs, _) = try leftoverIntent()
        chooseFirstScope(app)
        await settle()
        XCTAssertFalse(prefs.requested(), "旧电脑的意图不能带到新电脑上")
        XCTAssertFalse(prefs.enabled())
        XCTAssertNil(app.notice)
        XCTAssertEqual(app.phase, .main)
    }

    /// 完成页写「不开」也没写下来（目录只读 0o500：能读、建不出原子写的临时文件）：照常进首页、提示，盘上是真实值；
    /// 空间恢复后同一条写盘路径能写成。反证：同上一条——不写就不会提示，`notice` 断言红。
    func test_finishing_without_background_backup_write_failure_tells_the_user_and_recovers() async throws {
        let (app, prefs, prefsDir) = try leftoverIntent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: prefsDir.path)
        XCTAssertTrue(prefs.requested(), "前提：只读目录下读仍然有效")

        chooseFirstScope(app)
        await settle()
        XCTAssertEqual(app.phase, .main, "写不下来也照常进首页")
        XCTAssertEqual(app.notice?.message, L.s("setting_save_failed"))
        XCTAssertTrue(prefs.requested(), "没写下来：盘上仍是旧意图（不假装写成）")
        XCTAssertFalse(app.autoBackup, "显示值是盘上的真实值")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefsDir.path)
        app.notice = nil
        app.setAutoBackup(false)
        XCTAssertNil(app.notice)
        XCTAssertFalse(prefs.requested(), "空间恢复后再写能写成")
        XCTAssertFalse(prefs.enabled())
    }

    // MARK: #971

    /// 反证：把 `settingWriteFailed` 里的 `refresh()` 去掉、或让 `setAutoBackup` 先改显示值再写盘，下面的断言红。
    func test_failed_auto_backup_write_keeps_the_disk_value_and_tells_the_user() {
        let (app, engine, _) = make()
        XCTAssertFalse(app.autoBackup, "后台备份默认关（#982）")
        engine.failWrites = true
        app.setAutoBackup(true)
        XCTAssertFalse(app.autoBackup, "写失败：显示值必须是盘上的真实值，不是刚拨的新值")
        XCTAssertNotNil(app.notice, "写失败必须有可见反馈")
    }

    func test_successful_write_updates_the_value_without_a_notice() {
        let (app, engine, _) = make()
        app.setAutoBackup(true)
        XCTAssertTrue(app.autoBackup)
        XCTAssertTrue(engine.disk.auto)
        XCTAssertNil(app.notice)
    }

    func test_failed_notify_write_reverts_the_toggle() {
        let (app, engine, _) = make()
        engine.failWrites = true
        app.setNotifyToggle(false)
        XCTAssertTrue(app.notifyOnFailure, "盘上仍是开")
        XCTAssertNotNil(app.notice)
    }

    func test_failed_scope_save_does_not_advance_and_tells_the_user() async {
        let (app, _, media) = make()
        media.failSave = true
        app.phase = .chooseAlbums
        chooseFirstScope(app)
        await settle()
        XCTAssertNotNil(app.notice)
        XCTAssertEqual(media.disk, ["a"], "没写进去")
        XCTAssertEqual(app.scope, ["a"], "显示的范围是盘上的真实值")
        XCTAssertEqual(app.phase, .chooseAlbums, "没存上不能进首页")
    }

    func test_scope_read_failure_is_distinguishable_from_never_saved() {
        let (app, _, media) = make()
        media.failRead = true
        app.refresh()
        XCTAssertTrue(app.scopeUnreadable)
        XCTAssertNil(app.scope)
        media.failRead = false
        media.disk = nil // 从未保存
        app.refresh()
        XCTAssertFalse(app.scopeUnreadable, "从未保存不是读失败")
    }

    // MARK: #982

    /// 反证：把 `setWifiOnly(false)` 改回直接写盘，`wifi=false` 出现在 calls 里，本条红。
    func test_turning_wifi_only_off_asks_first_and_cancel_writes_nothing() {
        let (app, engine, _) = make()
        app.setWifiOnly(false)
        XCTAssertTrue(app.pendingWifiOff)
        XCTAssertTrue(app.wifiOnly, "确认前开关不动")
        XCTAssertFalse(engine.calls.contains("wifi=false"), "确认前不写盘")
        app.cancelWifiOff()
        XCTAssertFalse(app.pendingWifiOff)
        XCTAssertTrue(app.wifiOnly)
        XCTAssertTrue(engine.disk.wifi)
    }

    func test_confirming_wifi_off_saves_and_turning_on_needs_no_confirmation() {
        let (app, engine, _) = make()
        app.setWifiOnly(false)
        app.confirmWifiOff()
        XCTAssertFalse(app.pendingWifiOff)
        XCTAssertFalse(app.wifiOnly)
        XCTAssertFalse(engine.disk.wifi)
        app.setWifiOnly(true)
        XCTAssertFalse(app.pendingWifiOff, "打开不需要确认")
        XCTAssertTrue(engine.disk.wifi)
    }

    func test_confirmed_wifi_off_that_fails_to_save_snaps_back_with_a_notice() {
        let (app, engine, _) = make()
        engine.failWrites = true
        app.setWifiOnly(false)
        app.confirmWifiOff()
        XCTAssertTrue(app.wifiOnly)
        XCTAssertNotNil(app.notice)
    }

    // MARK: #1263 时间档、首页后台备份卡、照片页空状态

    /// 编辑范围：从今天起 → 全部 = 放宽，走 SCOPE_ADDED（相册没变也要补扫）；改回从今天起 = 缩小，不叫醒。
    /// 反证：`albumsChosen` 只看 added 不看 widened，第一段的 wake 断言红。
    func test_from_today_to_all_wakes_and_back_does_not() async {
        let (app, engine, media) = make()
        media.since = .since(ms: 1_000)
        app.albumsChosen(["a"], known: ["a", "b"], wantsAll: true, firstTime: false)
        await settle()
        XCTAssertEqual(media.since, .all)
        XCTAssertEqual(engine.calls.filter { $0 == "wake" }.count, 1, "放宽 → 补扫")

        app.albumsChosen(["a"], known: ["a", "b"], wantsAll: false, firstTime: false)
        await settle()
        if case .since = media.since {} else { XCTFail("改回从今天起") }
        XCTAssertEqual(engine.calls.filter { $0 == "wake" }.count, 1, "缩小 → 不叫醒，没传的从待办里消失")
        XCTAssertEqual(app.phase, .main, "编辑不改页面阶段")
    }

    /// 编辑相册、时间档仍是「从今天起」：起点不往后挪。
    func test_editing_albums_keeps_the_from_today_anchor() async {
        let (app, _, media) = make()
        media.since = .since(ms: 1_000)
        app.albumsChosen(["a", "b"], known: ["a", "b"], wantsAll: false, firstTime: false)
        await settle()
        XCTAssertEqual(media.since, .since(ms: 1_000))
    }

    /// 首页卡：后台备份没开、没关过卡 → 显示；点「开启」只写意图（iOS 没有 App 内授权框）→ 消失。
    func test_background_card_enables_background_backup() {
        let (app, engine, _) = make()
        XCTAssertTrue(app.showsBackgroundCard)
        app.enableBackgroundFromCard()
        XCTAssertTrue(engine.disk.auto)
        XCTAssertFalse(app.showsBackgroundCard)
    }

    /// 「不用了」→ 落盘、不再显示。写失败卡片仍在并提示。
    func test_background_card_dismiss_hides_it() {
        let (app, engine, _) = make()
        app.dismissBackgroundCard()
        XCTAssertFalse(app.showsBackgroundCard)
        XCTAssertTrue(engine.cardDismissed)

        let (failing, failingEngine, _) = make()
        failingEngine.failWrites = true
        failing.dismissBackgroundCard()
        XCTAssertTrue(failing.showsBackgroundCard, "没写下来就还在")
        XCTAssertNotNil(failing.notice)
    }

    /// 照片页空库两种说法：没选相册 → 引导去选；选了相册（含「最近项目」）→ 同一句（10-29 文案定稿 C8）。
    func test_photos_empty_hint_follows_the_scope() async {
        let (app, _, media) = make()
        app.refreshExistingAlbums()
        await settle()
        XCTAssertEqual(app.photosEmptyHint, .albums, "范围 [a]：选了相册就只有一种说法，不按「最近项目」分支")
        media.disk = ["b"]
        app.refresh()
        XCTAssertEqual(app.photosEmptyHint, .albums)
        media.disk = []
        app.refresh()
        XCTAssertEqual(app.photosEmptyHint, .chooseAlbums)
        media.disk = nil
        app.refresh()
        XCTAssertEqual(app.photosEmptyHint, .chooseAlbums, "从未保存也是没选相册")
    }

    /// 设置行的时间档一律写日期（10-29 文案定稿）：今天也写「10月29日起的照片」，以前某天写那一天；全部 →「含以前的照片」。
    /// 设置行用 scope_value_*（英文比选项短）；选范围页的选项用 scope_time_*，没存过时日期是今天。
    func test_scope_time_label() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_793_259_000) // 2026-10-29 15:30 +08:00
        let midnight: Int64 = 1_793_203_200_000
        let zh = Locale(identifier: "zh_CN")
        XCTAssertEqual(SettingsScreen.timeLabel(.since(ms: midnight), now: now, calendar: cal, locale: zh), L.f("scope_value_since", "10月29日"))
        XCTAssertEqual(SettingsScreen.timeLabel(.all, now: now, calendar: cal, locale: zh), L.s("scope_value_all"))
        let earlier = SettingsScreen.timeLabel(.since(ms: midnight - 86_400_000), now: now, calendar: cal, locale: zh)
        XCTAssertEqual(earlier, L.f("scope_value_since", "10月28日"))
        // 选项：没存过 / 存的是「全部」→ 今天；存过某天 → 那一天。
        XCTAssertEqual(BucketScreen.sinceOptionLabel(nil, now: now, calendar: cal, locale: zh), L.f("scope_time_since_date", "10月29日"))
        XCTAssertEqual(BucketScreen.sinceOptionLabel(.all, now: now, calendar: cal, locale: zh), L.f("scope_time_since_date", "10月29日"))
        XCTAssertEqual(BucketScreen.sinceOptionLabel(.since(ms: midnight - 86_400_000), now: now, calendar: cal, locale: zh),
                       L.f("scope_time_since_date", "10月28日"))
        XCTAssertNotEqual(L.s("scope_value_since"), "scope_value_since", "文案已打包")
    }

    /// 「选择相册」：切到设置 tab 并请设置页推出选范围页。
    func test_choose_albums_opens_the_scope_editor() {
        let (app, _, _) = make()
        app.openScopeEditor()
        XCTAssertEqual(app.tab, .settings)
        XCTAssertTrue(app.wantsScopeEditor)
    }

    // MARK: #972

    /// 反证：把 runCommand 里的 `catch { commandFailed }` 换回吞掉，notice 为 nil，本条红。
    func test_failed_commands_are_reported_not_swallowed() async {
        for (name, run) in [("retry", { (app: AppModel) in app.retry() }),
                            ("restore", { $0.restoreSkipped() })] {
            let (app, engine, _) = make()
            engine.failCommands = true
            run(app)
            await settle()
            XCTAssertNotNil(app.notice, "\(name) 出错必须有反馈")
            XCTAssertFalse(app.commandInFlight, "\(name) 出错之后按钮要能再点")
        }
    }

    func test_cancel_remaining_error_is_reported_but_not_allowed_state_is_not_an_error() async {
        let (app, engine, _) = make()
        let snapshot = RemainingSnapshot(count: 3, takenAtMs: 0, targets: [])
        engine.failCommands = true
        app.cancelRemaining(snapshot)
        await settle()
        XCTAssertNotNil(app.notice, "执行出错要提示")

        let (app2, engine2, _) = make()
        engine2.cancelResult = nil // 状态不允许
        app2.cancelRemaining(snapshot)
        await settle()
        XCTAssertNil(app2.notice, "状态不允许不是错误：不弹失败提示")
        XCTAssertTrue(engine2.calls.contains("cancel"))
    }

    func test_snapshot_failure_is_reported() async {
        let (app, _, _) = make()
        let snap = await app.remainingSnapshot()
        XCTAssertNil(snap)
        XCTAssertNotNil(app.notice)
    }
}
