@testable import PPassCore
import UIKit
import XCTest
@testable import PPass

/// #971 设置写盘失败回到真实值并提示 / #972 用户命令出错有反馈 / #982 关「仅 Wi‑Fi」先确认、后台备份默认关。
/// 引擎与相册换成可注入失败的替身，AppModel 是真的。
@MainActor
final class SettingsFeedbackTests: XCTestCase {
    private struct Boom: Error {}
    private struct StubPayload: PickedPayload {}

    /// 「盘」：写失败时不动，读永远是盘上的值。
    private final class StubEngine: BackupEngine {
        var disk = (wifi: true, auto: false, notify: true)
        var failWrites = false
        var failCommands = false
        var cancelResult: Int?
        var calls: [String] = []

        var stubFacts = FlowFacts()
        func facts() -> FlowFacts { stubFacts }
        func observe(_ onChange: @escaping () -> Void) {}
        func pauseOrResume() async {}
        func wake() async { calls.append("wake") }
        var rule = true
        var allowedSent = 0
        func autoRule() -> Bool { rule }
        func setAutoRule(_ on: Bool) throws { calls.append("rule=\(on)"); if failWrites { throw Boom() }; rule = on }
        func sendAllowedPhotos() async -> Int { calls.append("sendAllowed"); return allowedSent }
        func pickedSummary() -> PickedBatchSummary? { nil }
        /// 登记上几张（nil = 全部登记上）；0 = 一张没登记上。
        var pickedAdds: Int?
        func addPicked(_ items: [(fileName: String, mimeType: String, payload: PickedPayload)]) async -> Int {
            calls.append("picked"); return pickedAdds ?? items.count
        }
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
        func finishOnboarding() throws { calls.append("onboarded"); if failOnboarded { throw Boom() }; onboarded = true }
        /// 演示配对（`FakePairing`）是已配对：默认当作做过决定，冷启动进照片页；冷启动用例自己改。
        var onboarded = true
        func onboardedCurrent() -> Bool { onboarded }
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
        var pendingAccess = false
        func pendingFullPhotoAccess() -> Bool { pendingAccess }
        func setPendingFullPhotoAccess(_ pending: Bool) throws { if failWrites { throw Boom() }; pendingAccess = pending }
        var refresh: BackgroundRefreshAvailability = .available
        func backgroundRefresh() -> BackgroundRefreshAvailability { refresh }
        // #1763 素材文件夹：本测试不涉及，给最小组面。
        func folderSourceCount() -> Int { 0 }
        func folderSources() async -> [FolderSourceInfo] { [] }
        func addFolderSource(at url: URL, displayName: String) async throws {}
        func reauthorizeFolderSource(id: String, at url: URL) async throws {}
        func removeFolderSource(id: String) throws {}
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

    private func make(onboarded: Bool = true) -> (AppModel, StubEngine, StubMedia) {
        let engine = StubEngine(), media = StubMedia()
        engine.onboarded = onboarded
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

    /// 首次选范围点「开始备份」= 决定页选了范围备份（#1263 没有完成页）：保存范围后记「连过这台电脑」、「自动备份」规则打开（#1323）、
    /// 后台备份写「关」、唤醒引擎、直接进首页。
    /// 反证：去掉 `finishFirstScope` 的调用，onboarded 不出现、phase 停在 chooseAlbums，本条红；去掉里面写规则那行，rule=true 不出现，本条红。
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
        XCTAssertEqual(Array(engine.calls.prefix(3)), ["onboarded", "rule=true", "auto=false"], "先记连过，规则随范围备份打开，后台备份默认关")
        XCTAssertTrue(app.autoRule)
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

    /// #1323（改断言、保意图：原「首次配对直接进照片页」）：首次 / 新电脑配对 → 决定页；配对这一步不弹照片权限框，
    /// 也**不落盘**「连过这台」（落盘在决定页的选择回调）；规则与后台备份按「关」写一次。
    /// 反证：把 `finishOnboarding()` 留在 `paired` 里，onboarded 出现，本条红；`paired` 仍进 `.main`，phase 断言红。
    func test_first_pairing_goes_to_the_decision_page_without_marking() {
        let (app, engine, media) = make()
        media.granted = nil
        app.paired(firstTime: true, settingSaveFailed: false)
        XCTAssertEqual(app.phase, .decision)
        XCTAssertEqual(media.requested, 0)
        XCTAssertFalse(engine.calls.contains("onboarded"), "配对成功本身不算连过")
        XCTAssertTrue(engine.calls.contains("rule=false"))
        XCTAssertTrue(engine.calls.contains("auto=false"))
    }

    /// 连回以前连过的电脑直接进首页，不管照片权限问没问过；不重写规则、不落盘。
    func test_known_desktop_goes_home() {
        let (known, engine, media) = make()
        media.granted = nil
        known.paired(firstTime: false, settingSaveFailed: false)
        XCTAssertEqual(known.phase, .main)
        XCTAssertTrue(engine.calls.isEmpty, "保留原配置：\(engine.calls)")
    }

    /// #1323（改断言、保意图：原「部分 / 拒绝照常走完选范围」）：决定页主按钮申请照片权限——全部允许 → 选范围页；
    /// 拒绝 → 系统选图（单张备份），不落盘。不新增出口。
    /// 反证：`decisionLanding` 恒返回 `.chooseScope`，拒绝一轮红。
    func test_decision_main_button_lands_by_photo_access() async {
        for (answer, expected) in [(MediaAccess.full, AppModel.Phase.chooseAlbums), (.none, .decision)] {
            let (app, engine, media) = make()
            media.granted = nil
            media.answer = answer
            app.paired(firstTime: true, settingSaveFailed: false)
            app.decisionChooseScope()
            await settle()
            XCTAssertEqual(media.requested, 1, "\(answer)")
            XCTAssertEqual(app.phase, expected, "\(answer)")
            XCTAssertEqual(app.pickerRequested, answer != .full, "\(answer)")
            XCTAssertEqual(app.access, answer, "页面要拿到系统框之后的权限档")
            XCTAssertFalse(engine.calls.contains("onboarded"), "还没做出选择：\(answer)")
            XCTAssertFalse(engine.calls.contains("sendAllowed"), "\(answer)")
        }
    }

    /// #1323 部分允许：iOS 权限框里系统已弹过选照片页，那次选择就是「系统选图」——当场落盘 via=pick、进照片页
    /// （不停在决定页等登记，真机上停着按钮还能再点），已授权的照片在后台登记（单张备份）；不再弹 App 的选图器
    /// （真机实测曾让用户选两遍）。授权集为空也往下走：用户已经做了选择。
    /// 反证：部分允许改回 `pickerRequested = true`（旧行为），picker / phase / onboarded 断言红。
    func test_decision_partial_registers_system_selection_without_second_picker() async {
        for allowed in [2, 0] {
            let (app, engine, media) = make()
            media.granted = nil
            media.answer = .partial
            engine.allowedSent = allowed
            app.paired(firstTime: true, settingSaveFailed: false)
            app.decisionChooseScope()
            await settle()
            XCTAssertFalse(app.pickerRequested, "不弹第二个选图器")
            XCTAssertTrue(engine.calls.contains("sendAllowed"), "\(engine.calls)")
            XCTAssertTrue(engine.calls.contains("onboarded"), "做了选择就落盘：\(allowed)")
            XCTAssertEqual(app.phase, .main, "\(allowed)")
        }
    }

    /// #1373 评审（定案「决定开始处理后，决定页两个按钮都不可点，直到进照片页或回到决定页」）：
    /// 处理中再点（任一按钮）不触发第二次；选图取消 / 没登记上 / 换页之后能再点。
    /// 反证：去掉 `decisionChooseScope` / `decisionPickPhotos` 开头的 `guard !decisionBusy`，requested / picker 断言红；
    /// 去掉 `pickerRequested` 收起时的解锁，「取消后能再点」那段红。
    func test_decision_buttons_lock_while_processing_and_unlock_on_every_exit() async {
        let (app, engine, media) = make()
        media.granted = nil
        media.answer = .none
        app.paired(firstTime: true, settingSaveFailed: false)
        XCTAssertFalse(app.decisionBusy)

        app.decisionPickPhotos()
        XCTAssertTrue(app.decisionBusy, "点了就锁")
        app.decisionChooseScope() // 另一个按钮
        app.decisionPickPhotos()  // 同一个按钮
        await settle()
        XCTAssertEqual(media.requested, 0, "处理中再点不触发第二次")

        app.pickerRequested = false // 系统选图器取消 / 下滑关掉（不回调 pickedChosen）
        XCTAssertFalse(app.decisionBusy, "取消后能再点")
        app.decisionChooseScope()
        await settle()
        XCTAssertEqual(media.requested, 1)
        XCTAssertTrue(app.pickerRequested, "拒绝 → 系统选图，仍在处理中")
        XCTAssertTrue(app.decisionBusy)
        app.decisionChooseScope()
        await settle()
        XCTAssertEqual(media.requested, 1, "选图器开着时再点主按钮不再申请")

        let item: (fileName: String, mimeType: String, payload: PickedPayload) = ("a.jpg", "image/jpeg", StubPayload())
        app.pickerRequested = false
        engine.pickedAdds = 0
        app.pickedChosen([item])
        await settle()
        XCTAssertEqual(app.phase, .decision)
        XCTAssertFalse(app.decisionBusy, "一张没登记上：回到决定页，能再点")

        media.answer = .full
        app.decisionChooseScope()
        await settle()
        XCTAssertEqual(app.phase, .chooseAlbums)
        XCTAssertFalse(app.decisionBusy, "进了下一页就解锁")
        app.leaveFirstScope()
        XCTAssertEqual(app.phase, .decision)
        XCTAssertFalse(app.decisionBusy, "从选范围页回到决定页能再点")
    }

    /// 决定页的范围出口：选范围页返回 → 回决定页（还没做决定）；再进、保存 → 落盘 via=scope、进照片页。
    /// 反证：`leaveFirstScope` 改成进 `.main`，第一段红；`finishFirstScope` 不落盘，onboarded 断言红。
    func test_decision_scope_exit_back_returns_and_save_marks() async {
        let (app, engine, media) = make()
        media.disk = nil
        app.paired(firstTime: true, settingSaveFailed: false)
        app.decisionChooseScope()
        await settle()
        XCTAssertEqual(app.phase, .chooseAlbums)
        app.leaveFirstScope()
        XCTAssertEqual(app.phase, .decision, "返回 = 还没做决定")
        XCTAssertFalse(engine.calls.contains("onboarded"))
        app.decisionChooseScope()
        await settle()
        chooseFirstScope(app)
        await settle()
        XCTAssertEqual(engine.calls.filter { $0 == "onboarded" }.count, 1)
        XCTAssertEqual(app.phase, .main)
    }

    /// 决定页的单张出口：系统选图选完、登记成功 → 落盘 via=pick、进照片页；取消（空）或一张没登记上 → 留在决定页、不落盘。
    /// 反证：`pickedChosen` 里去掉 `markDecided(via: "pick")`，onboarded 断言红；去掉 `added > 0` 守卫，「没登记上」那段红。
    func test_decision_pick_exit_marks_only_when_registered() async {
        let item: (fileName: String, mimeType: String, payload: PickedPayload) = ("a.jpg", "image/jpeg", StubPayload())
        let (app, engine, _) = make()
        app.paired(firstTime: true, settingSaveFailed: false)
        app.decisionPickPhotos()
        XCTAssertTrue(app.pickerRequested)
        app.pickedChosen([]) // 选图取消
        await settle()
        XCTAssertEqual(app.phase, .decision)

        engine.pickedAdds = 0
        app.pickedChosen([item])
        await settle()
        XCTAssertEqual(app.phase, .decision, "一张没登记上不算做了决定")
        XCTAssertFalse(engine.calls.contains("onboarded"))

        engine.pickedAdds = nil
        app.pickedChosen([item])
        await settle()
        XCTAssertEqual(engine.calls.filter { $0 == "onboarded" }.count, 1)
        XCTAssertEqual(app.phase, .main)

        app.pickedChosen([item]) // 照片页里再挑：不再落盘
        await settle()
        XCTAssertEqual(engine.calls.filter { $0 == "onboarded" }.count, 1)
    }

    /// 冷启动（判断 B）：有配对、这台没有记录（含决定页被杀）→ 决定页；有记录 → 照片页。
    /// 反证：`init` 改回「有配对就进 .main」，第一段红。
    func test_cold_launch_without_a_record_lands_on_the_decision_page() {
        let (fresh, _, _) = make(onboarded: false)
        XCTAssertEqual(fresh.phase, .decision)
        let (known, _, _) = make(onboarded: true)
        XCTAssertEqual(known.phase, .main)
    }

    /// 打开「自动备份」规则（全部允许）且已有范围：也进选范围页确认范围（#1323，对位 Android），不再直接开始。
    /// 反证：改回 `if noAlbums { openScopeEditor() } else { wake }`，wantsScopeEditor 断言红。
    func test_turning_the_rule_on_with_a_scope_still_opens_the_scope_editor() async {
        let (app, engine, _) = make()
        engine.rule = false
        app.refresh()
        app.refreshExistingAlbums()
        await settle()
        XCTAssertFalse(app.noAlbums, "前提：已有范围")
        app.setAutoRule(true)
        await settle()
        XCTAssertTrue(app.autoRule)
        XCTAssertTrue(app.wantsScopeEditor)
        XCTAssertEqual(app.tab, .settings)
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

    /// 配对结局带着「清意图没写下来」：照常往下走（#1323 起新电脑进决定页），并提示。反证：去掉 `paired` 里设 notice 那段，本条红。
    func test_new_desktop_intent_clear_failure_still_goes_on_and_tells_the_user() {
        let (app, _, _) = make()
        app.paired(firstTime: true, settingSaveFailed: true)
        XCTAssertEqual(app.phase, .decision, "不拦配对")
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


    /// #1324（改写自原「照片页空库两种说法」：「没选相册 → 引导去选」并入引导位第一步）：引导位的事实来自真实开关——
    /// 规则开 + 选了相册（含「最近项目」）才算范围备份开着；没选 / 从未保存 / 规则关 → 第一步。
    func test_photos_guide_reads_the_real_switches() async {
        let (app, engine, media) = make()
        app.refreshExistingAlbums()
        await settle()
        XCTAssertTrue(app.guideFacts.scopeOn, "规则开、范围 [a]")
        XCTAssertEqual(app.photosGuide, .none, "还没传成功：不出卡")
        media.disk = []
        app.refresh()
        XCTAssertEqual(app.photosGuide, .enableScope, "一个相册都没选")
        media.disk = nil
        app.refresh()
        XCTAssertEqual(app.photosGuide, .enableScope, "从未保存也是没选相册")
        media.disk = ["a"]
        engine.rule = false
        app.refresh()
        XCTAssertEqual(app.photosGuide, .enableScope, "规则关")
        engine.rule = true
        engine.stubFacts.lastSuccessAt = 1
        app.refresh()
        XCTAssertEqual(app.photosGuide, .enableBackground, "第一张已传、后台没开")
        app.setAutoBackup(true)
        XCTAssertEqual(app.photosGuide, .none, "都开了")
    }

    /// × 即走完：落盘「onboarding 已走完」（与 Android 同一个 background_backup_offer.json），之后开关怎么变都不再出卡；
    /// 范围内暂无照片的现状不受 × 影响。
    /// 反证：`dismissGuide` 不落盘（不调 dismissBackgroundCard），card-dismissed 断言红；现状提示也看 ×，最后一段红。
    func test_dismissing_the_guide_ends_it_but_not_the_scope_status_line() async {
        let (app, engine, _) = make()
        app.refreshExistingAlbums()
        await settle()
        engine.stubFacts.inScopeTotal = 0
        app.refresh()
        XCTAssertNotNil(app.scopeEmptyHint, "范围开着、范围里还没有照片 → 说现状")
        engine.stubFacts.lastSuccessAt = 1
        app.refresh()
        XCTAssertEqual(app.photosGuide, .enableBackground)
        app.dismissGuide()
        XCTAssertTrue(engine.calls.contains("card-dismissed"))
        app.refresh()
        XCTAssertEqual(app.photosGuide, .none)
        engine.rule = false
        app.refresh()
        XCTAssertEqual(app.photosGuide, .none, "规则关了也不再出第一步")
        engine.rule = true
        app.refresh()
        XCTAssertNotNil(app.scopeEmptyHint, "不受 × 影响")
        engine.stubFacts.inScopeTotal = 1
        app.refresh()
        XCTAssertNil(app.scopeEmptyHint, "有了第一张就不说")
    }

    /// 第二步按系统真实状态现算（owner 判断）：App 里「后台备份」开着但系统「后台 App 刷新」被关 → 仍出卡（按钮「去设置」）；
    /// 回到前台读到系统已放行 → 卡消失；被限制（用户改不了）→ 不劝。按钮不预先写系统侧任何东西。
    /// 反证：卡片判定改回只看意图（`backgroundOn: autoBackup`），「意图开、系统关」那段红。
    func test_background_step_follows_the_real_system_state() async {
        let (app, engine, _) = make()
        app.refreshExistingAlbums()
        await settle()
        engine.stubFacts.lastSuccessAt = 1
        engine.disk.auto = true
        engine.refresh = .denied
        app.sceneBecameActive()
        XCTAssertEqual(app.photosGuide, .enableBackground, "意图开着、系统后台 App 刷新关着：后台备份并没有生效")
        XCTAssertEqual(app.backgroundGuideActionKey, "background_refresh_notice_action", "按钮「去设置」")
        let before = engine.calls
        engine.refresh = .available // 用户在系统设置里打开后回到前台
        app.sceneBecameActive()
        XCTAssertEqual(app.photosGuide, .none, "回到前台按真实状态重算")
        XCTAssertEqual(engine.calls, before, "没有任何预先写入")
        engine.refresh = .restricted
        app.sceneBecameActive()
        XCTAssertEqual(app.photosGuide, .none, "被限制：用户改不了，引导位不劝")
    }

    /// 系统已放行、只差 App 里的「后台备份」开关（系统读不到这一项）：按钮「开启」，写这一项。
    func test_background_step_with_refresh_available_turns_on_the_app_switch() async {
        let (app, engine, _) = make()
        app.refreshExistingAlbums()
        await settle()
        engine.stubFacts.lastSuccessAt = 1
        engine.refresh = .available
        app.refresh()
        XCTAssertEqual(app.photosGuide, .enableBackground)
        XCTAssertEqual(app.backgroundGuideActionKey, "photos_guide_enable")
        app.guideAction(.enableBackground)
        XCTAssertTrue(engine.calls.contains("auto=true"))
        XCTAssertEqual(app.photosGuide, .none)
    }

    /// × 写不下来：卡片留着、提示用户。
    func test_dismiss_write_failure_keeps_the_card_and_tells_the_user() async {
        let (app, engine, _) = make()
        engine.failWrites = true
        engine.rule = false
        app.refresh()
        app.dismissGuide()
        XCTAssertEqual(app.photosGuide, .enableScope)
        XCTAssertEqual(app.notice?.message, L.s("setting_save_failed"))
    }

    /// 第一步的按钮：规则开着（只是没选相册）→ 直达选范围页。
    func test_enable_scope_with_the_rule_on_opens_the_scope_editor() {
        let (app, engine, media) = make()
        media.disk = []
        app.refresh()
        XCTAssertTrue(engine.rule)
        app.guideAction(.enableScope)
        XCTAssertTrue(app.wantsScopeEditor)
        XCTAssertEqual(app.tab, .settings)
    }

    /// 部分照片权限下开自动备份（引导卡「开启」/ 设置开关）：iOS 不会再弹授权框，同一意图的做法是去系统设置改成「所有照片」；
    /// 回来按真实权限现算——改成全部 → 规则开、进选范围页（同 Android 授权成功）；仍是部分（含没改直接回来）→ 传一次允许的照片
    /// + 瞬时提示、开关保持关。iOS 改照片权限会结束进程，所以「还没走完」的记号落盘，冷启动也接着走。不预写开关。
    /// 反证：去掉「已是部分 → 去设置」那段，settings / requested 断言红；去掉 `sceneBecameActive` 里的接续，回前台两段红；
    /// 去掉 init 里的接续，冷启动那段红。
    func test_partial_access_enable_goes_to_settings_and_resumes_by_real_access() async {
        for (back, ruleOn) in [(MediaAccess.full, true), (.partial, false)] {
            let (app, engine, media) = make()
            var opened = 0
            app.settingsOpener = { opened += 1 }
            try? engine.setAutoRule(false)
            media.granted = .partial
            app.refresh()
            XCTAssertEqual(app.scopeGuideActionKey, "background_refresh_notice_action", "部分权限、规则关：按钮说「去设置」")
            engine.calls.removeAll()
            app.guideAction(.enableScope)
            await settle()
            XCTAssertEqual(opened, 1, "去系统设置")
            XCTAssertEqual(media.requested, 0, "iOS 不会再弹授权框，不去申请")
            XCTAssertFalse(app.autoRule, "不预写开关")
            XCTAssertTrue(engine.pendingAccess, "记号落盘")
            XCTAssertTrue(engine.calls.isEmpty, "去设置之前什么都不做：\(engine.calls)")

            media.granted = back
            app.sceneBecameActive()
            await settle()
            XCTAssertFalse(engine.pendingAccess, "接过就清")
            XCTAssertEqual(app.autoRule, ruleOn, "\(back)")
            if back == .full {
                XCTAssertTrue(app.wantsScopeEditor, "改成全部 → 进选范围页")
                XCTAssertNil(app.ruleNote)
            } else {
                XCTAssertTrue(engine.calls.contains("sendAllowed"), "仍是部分 → 传一次允许的照片")
                XCTAssertEqual(app.ruleNote, L.s("auto_backup_rule_partial_hint"), "只有开关下方一行现状，不弹提示")
            }
            engine.calls.removeAll()
            app.sceneBecameActive()
            await settle()
            XCTAssertFalse(engine.calls.contains("sendAllowed"), "只接一次：\(back)")
        }
    }

    /// iOS 改照片权限后结束了进程：带着记号冷启动（新的 AppModel）→ 按真实权限接着走，改成全部就进选范围页。
    /// 反证：去掉 init 里的 `resumeAutoRuleAfterSettings()`，本条红。
    func test_pending_full_access_resumes_on_cold_start() async {
        let (_, engine, media) = make()
        try? engine.setAutoRule(false)
        engine.pendingAccess = true
        media.granted = .full
        let fake = FakeBackend.make(.normal)
        let cold = AppModel(backend: Backend(isDemo: true, timeline: fake.timeline, live: fake.live, media: media, pairing: fake.pairing, engine: engine))
        await settle()
        XCTAssertFalse(engine.pendingAccess)
        XCTAssertTrue(cold.autoRule)
        XCTAssertTrue(cold.wantsScopeEditor)
    }

    /// 还没问过照片权限时开自动备份：系统会弹框（同 Android），选「部分」→ 传一次允许的照片、开关保持关，
    /// 开关下方只说现状（不弹「已传 N 张」：弹出时照片还没传，产品负责人 2026-11-04），不去设置。
    /// 反证：部分分支改回「已把你允许的 N 张…」，本条红。
    func test_first_prompt_partial_sends_allowed_without_settings_or_sent_claim() async {
        let (app, engine, media) = make()
        var opened = 0
        app.settingsOpener = { opened += 1 }
        try? engine.setAutoRule(false)
        media.granted = nil
        media.answer = .partial
        engine.allowedSent = 3
        app.refresh()
        XCTAssertEqual(app.scopeGuideActionKey, "photos_guide_enable")
        app.setAutoRule(true)
        await settle()
        XCTAssertEqual(media.requested, 1)
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(app.autoRule)
        XCTAssertTrue(engine.calls.contains("sendAllowed"))
        XCTAssertEqual(app.ruleNote, L.s("auto_backup_rule_partial_hint"))
    }

    // MARK: 拒绝后用户自己去系统设置改成「全部」再回来（产品负责人 2026-11-04 补的场景，两端同一预期）

    /// 场景 A：决定页「选择备份范围」→ 不允许 → 系统选图里取消 → 留在决定页；自己去设置改成全部回来 → 仍在决定页
    /// （决定还没做，回前台不替用户跳过、不落「连过」）；再点主按钮 → 不弹选图器、直接进选范围页。
    /// 反证：`sceneBecameActive` 里按权限把 phase 往前推，或 `decisionLanding(.full)` 不进选范围页，本条红。
    func test_scenario_a_full_access_granted_in_settings_keeps_decision_until_the_user_chooses() async {
        let (app, engine, media) = make(onboarded: false)
        media.granted = nil
        media.answer = .none
        app.paired(firstTime: true, settingSaveFailed: false)
        app.decisionChooseScope()
        await settle()
        XCTAssertTrue(app.pickerRequested, "拒绝 → 系统选图")
        app.pickerRequested = false
        app.pickedChosen([])
        await settle()
        XCTAssertEqual(app.phase, .decision, "选图取消：留在决定页")

        media.granted = .full
        app.sceneBecameActive()
        await settle()
        XCTAssertEqual(app.phase, .decision, "回前台不替用户做决定")
        XCTAssertFalse(engine.calls.contains("onboarded"))

        media.answer = .full
        app.decisionChooseScope()
        await settle()
        XCTAssertEqual(app.phase, .chooseAlbums, "已是全部：直接进选范围页")
        XCTAssertFalse(app.pickerRequested)
    }

    /// 场景 B：拒绝后挑了照片（单张备份）进了照片页；自己去设置改成全部回来 → 自动备份保持关（不替用户开）；
    /// 引导卡第一张、按钮是「开启」不是「去设置」；点它 → 不去设置、直接开并进选范围页；不出「自动备份已停止」。
    /// 反证：回前台按权限替用户把开关打开，或全部权限下按钮仍是「去设置」，本条红。
    func test_scenario_b_full_access_after_picking_does_not_turn_backup_on_for_the_user() async {
        let (app, engine, media) = make()
        var opened = 0
        app.settingsOpener = { opened += 1 }
        try? engine.setAutoRule(false)
        media.granted = .none
        app.refresh()
        media.granted = .full
        app.sceneBecameActive()
        await settle()
        XCTAssertFalse(app.autoRule, "不替用户开自动备份")
        XCTAssertEqual(app.photosGuide, .enableScope)
        XCTAssertEqual(app.scopeGuideActionKey, "photos_guide_enable", "全部权限：按钮是「开启」")
        XCTAssertFalse(app.autoRuleBlocked, "开关关着：不是「自动备份已停止」")

        app.guideAction(.enableScope)
        await settle()
        XCTAssertEqual(opened, 0, "全部权限：不去设置")
        XCTAssertTrue(app.autoRule)
        XCTAssertTrue(app.wantsScopeEditor, "直接进选范围页")
    }

    /// 场景 C：自动备份开着时权限被收回（自动备份已停止），用户没点「去设置」而是自己去设置改回全部再回来
    /// → 不再是「已停止」、开关仍开（不用碰开关，备份按开关恢复）。
    /// 反证：`refresh` 不重读权限，或回前台改了开关，本条红。
    func test_scenario_c_user_restores_full_access_on_their_own() async {
        let (app, engine, media) = make()
        XCTAssertTrue(engine.rule)
        media.granted = .partial
        app.refresh()
        XCTAssertTrue(app.autoRuleBlocked, "权限被收回：自动备份已停止")
        media.granted = .full
        app.sceneBecameActive()
        await settle()
        XCTAssertFalse(app.autoRuleBlocked, "回前台按真实权限现算")
        XCTAssertTrue(app.autoRule, "开关不动")
        XCTAssertFalse(engine.calls.contains("rule=false"))
    }

    /// 现状那一行：「从今天起」写日期，「全部」说所选相册。
    func test_scope_empty_hint_wording() async {
        let (app, engine, media) = make()
        app.refreshExistingAlbums()
        await settle()
        engine.stubFacts.inScopeTotal = 0
        media.since = .all
        app.refresh()
        XCTAssertEqual(app.scopeEmptyHint, L.f("photos_scope_empty_all", "Home-Computer"))
        let ms: Int64 = 1_793_203_200_000
        media.since = .since(ms: ms)
        app.refresh()
        XCTAssertEqual(app.scopeEmptyHint, L.f("photos_scope_empty_since", SettingsScreen.scopeDate(Date(timeIntervalSince1970: Double(ms) / 1000)), "Home-Computer"))
        XCTAssertNotEqual(L.s("photos_scope_empty_all"), "photos_scope_empty_all", "文案已打包")
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
