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
        func wake() async {}
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
        func shouldAskNotificationAtOnboarding() async -> Bool { false }
        func askNotificationAtOnboarding() async {}
        var failOnboarded = false
        func finishOnboarding() throws { calls.append("onboarded"); if failOnboarded { throw Boom() } }
        func wifiOnly() -> Bool { disk.wifi }
        func setWifiOnly(_ on: Bool) throws { calls.append("wifi=\(on)"); if failWrites { throw Boom() }; disk.wifi = on }
        func autoBackup() -> Bool { disk.auto }
        func setAutoBackup(_ on: Bool) throws { calls.append("auto=\(on)"); if failWrites { throw Boom() }; disk.auto = on }
        func promise() -> [PromiseNotice] { [] }
    }

    private final class StubMedia: MediaLibrary {
        var disk: Set<String>? = ["a"]
        var failSave = false
        var failRead = false
        func access() -> MediaAccess { .full }
        func requestAccess() async -> MediaAccess { .full }
        func albums() async throws -> [AlbumBucket] { [] }
        func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage? { nil }
        func savedScope() throws -> Set<String>? { if failRead { throw Boom() }; return disk }
        func knownAlbums() -> Set<String> { [] }
        func existingAlbumIds() async -> Set<String>? { ["a", "b"] }
        func saveScope(_ selected: Set<String>, known: Set<String>) async throws { if failSave { throw Boom() }; disk = selected }
    }

    private func make() -> (AppModel, StubEngine, StubMedia) {
        let engine = StubEngine(), media = StubMedia()
        let fake = FakeBackend.make(.normal)
        let backend = Backend(isDemo: true, timeline: fake.timeline, live: fake.live, media: media, pairing: fake.pairing, engine: engine)
        return (AppModel(backend: backend), engine, media)
    }

    /// 等主 actor 上排队的 Task 跑完。
    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 50_000_000) }

    // MARK: #1019

    /// 「连过这台电脑」在完成页点按钮时落盘，选不选后台备份都记（Android finishOnboarding）。反证：去掉 AppModel 里的调用，本条红。
    func test_finishing_onboarding_marks_the_desktop_either_way() async {
        for enable in [false, true] {
            let (app, engine, _) = make()
            app.finishOnboardingStarted(enableBackgroundBackup: enable)
            await settle()
            XCTAssertEqual(engine.calls.first, "onboarded", "完成页第一件事是记下连过（enable=\(enable)）")
            XCTAssertEqual(engine.calls.contains("auto=true"), enable)
            XCTAssertEqual(app.phase, .main)
        }
    }

    /// 记不下来：照样进首页（后果只是下次重连仍走首次设置），但要提示用户，不静默。
    func test_failed_onboarded_mark_still_enters_home_and_tells_the_user() async {
        let (app, engine, _) = make()
        engine.failOnboarded = true
        app.finishOnboardingStarted(enableBackgroundBackup: false)
        await settle()
        XCTAssertEqual(app.phase, .main)
        XCTAssertEqual(app.notice?.message, L.s("setting_save_failed"))
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
        app.albumsChosen(["a", "b"], known: ["a", "b"], firstTime: true)
        await settle()
        XCTAssertNotNil(app.notice)
        XCTAssertEqual(media.disk, ["a"], "没写进去")
        XCTAssertEqual(app.scope, ["a"], "显示的范围是盘上的真实值")
        if case .backupStarted = app.phase { XCTFail("没存上不能进「正在回家」") }
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

    func test_onboarding_choice_enables_or_leaves_background_backup() async {
        let (app, engine, _) = make()
        app.finishOnboardingStarted(enableBackgroundBackup: false)
        await settle()
        XCTAssertFalse(engine.disk.auto, "选「不开启」不写开")
        XCTAssertFalse(engine.calls.contains("auto=true"))
        app.finishOnboardingStarted(enableBackgroundBackup: true)
        await settle()
        XCTAssertTrue(engine.disk.auto)
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
