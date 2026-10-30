// #338：意图与偏好的小文件 store——每份都「写入 → 新实例（= 杀进程重启）→ 读回」真跑，损坏文件的处置与 Android 代码一致。
import Foundation
import XCTest
@testable import PPassCore

final class PrefsTests: XCTestCase {

    // MARK: AutoBackupPrefs

    func testAutoBackupDefaultsOffAndSurvivesRestart() throws {
        let tmp = TempDir()
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled(), "Android 代码的默认值是 autoEnabled=false（文件头注释写的「开启」与代码不符，以代码为准）")
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).requested())
        try AutoBackupPrefs(directory: tmp.url).setEnabled(true)
        try AutoBackupPrefs(directory: tmp.url).setRequested(true)
        let reopened = AutoBackupPrefs(directory: tmp.url)
        XCTAssertTrue(reopened.enabled())
        XCTAssertTrue(reopened.requested())
    }

    func testAutoBackupCorruptFileFallsBackToDefaultsAndLogs() throws {
        let tmp = TempDir()
        tmp.write(AutoBackupPrefs.fileName, "{not json")
        let logger = RecordingLogger()
        let prefs = AutoBackupPrefs(directory: tmp.url, logger: logger)
        XCTAssertFalse(prefs.enabled())
        XCTAssertFalse(prefs.requested())
        XCTAssertTrue(logger.contains("auto_backup_prefs.json unreadable"), "\(logger.lines)")
        // 损坏之后照常能写回。
        try prefs.setEnabled(true)
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).enabled())
    }

    /// 旧文件只有 `paused`：autoEnabled = !paused；没有 userRequested 时意图退回生产者状态。
    func testAutoBackupLegacyPausedKey() {
        let tmp = TempDir()
        tmp.write(AutoBackupPrefs.fileName, #"{"paused":false}"#)
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).enabled())
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).requested())
        tmp.write(AutoBackupPrefs.fileName, #"{"paused":true}"#)
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled())
        tmp.write(AutoBackupPrefs.fileName, #"{"autoEnabled":"yes"}"#)
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled(), "类型不对按缺键处理")
    }

    /// MOB-93：断开停生产者、留意图。反证：把 suspend 写成同时清 userRequested，requested() 变 false，红。
    func testSuspendForPairingChangeStopsProducerKeepsIntent() throws {
        let tmp = TempDir()
        let prefs = AutoBackupPrefs(directory: tmp.url)
        try prefs.setEnabled(true)
        try prefs.suspendForPairingChange()
        let reopened = AutoBackupPrefs(directory: tmp.url)
        XCTAssertFalse(reopened.enabled())
        XCTAssertTrue(reopened.requested())
    }

    /// #982（Android MOB-93 / MainActivity 配对完成两条路）：连回以前连过的电脑 → 按留下的意图恢复；换新电脑 → 清意图，要重新问。
    /// 反证：把 `knownDesktop` 的两个分支对调，下面两条都红。
    func testPairingKnownDesktopRestoresRequestedIntent() throws {
        let tmp = TempDir()
        let prefs = AutoBackupPrefs(directory: tmp.url)
        try prefs.setRequested(true)
        try prefs.applyOnPairing(knownDesktop: true)
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).enabled(), "老电脑、用户要过后台备份 → 恢复生产者")
        XCTAssertTrue(AutoBackupPrefs(directory: tmp.url).requested())
    }

    func testPairingKnownDesktopWithoutIntentStaysOff() throws {
        let tmp = TempDir()
        let prefs = AutoBackupPrefs(directory: tmp.url)
        try prefs.setRequested(false)
        try prefs.applyOnPairing(knownDesktop: true)
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled())
    }

    func testPairingNewDesktopClearsIntentAndDoesNotInheritIt() throws {
        let tmp = TempDir()
        let prefs = AutoBackupPrefs(directory: tmp.url)
        try prefs.setRequested(true)   // 上一台电脑留下的意图（断开只停生产者、留意图）
        try prefs.setEnabled(false)
        try prefs.applyOnPairing(knownDesktop: false)
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).requested(), "新电脑 = 新的信任关系：意图清掉，等完成页让用户选")
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled(), "新电脑不沿用上一台的后台意图")
    }

    func testPairingWriteFailureThrows() throws {
        let tmp = TempDir()
        tmp.write(AutoBackupPrefs.fileName, "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tmp.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.url.path) }
        XCTAssertThrowsError(try AutoBackupPrefs(directory: tmp.url).applyOnPairing(knownDesktop: false), "写盘失败要抛给调用方，不吞")
    }

    /// #1039：用户的选择（意图 + 生产者）一次落盘。目录只读（0o500：能读、建不出原子写的临时文件）→ 抛出、盘上原样；
    /// 恢复可写后同一次调用写成。反证：让 `setUserChoice` 吞掉错误，第一条断言红；让它只写 `autoEnabled`，后两条红。
    func testUserChoiceIsOneWriteAndRecoversAfterTheDirectoryIsWritableAgain() throws {
        let tmp = TempDir()
        let prefs = AutoBackupPrefs(directory: tmp.url)
        try prefs.set(requested: true, enabled: false) // 断开旧电脑后：停生产者、留意图（MOB-93）
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmp.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.url.path) }
        XCTAssertTrue(prefs.requested(), "前提：只读目录下读仍然有效")

        XCTAssertThrowsError(try prefs.setUserChoice(false), "写盘失败要抛给调用方，不吞")
        XCTAssertTrue(prefs.requested(), "没写下来：盘上仍是旧意图")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.url.path)
        try prefs.setUserChoice(false)
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).requested())
        XCTAssertFalse(AutoBackupPrefs(directory: tmp.url).enabled())
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.file(AutoBackupPrefs.fileName))) as? [String: Any]
        XCTAssertEqual(saved?["userRequested"] as? Bool, false)
        XCTAssertEqual(saved?["autoEnabled"] as? Bool, false)
    }

    func testAutoBackupResumeDecision() {
        XCTAssertEqual(AutoBackupResume.decide(userRequested: false, backgroundAuthorized: true), .leaveOff)
        XCTAssertEqual(AutoBackupResume.decide(userRequested: true, backgroundAuthorized: true), .enable)
        XCTAssertEqual(AutoBackupResume.decide(userRequested: true, backgroundAuthorized: false), .suspend)
    }

    // MARK: BackupSettings

    func testBackupSettingsDefaultWifiOnlyAndIgnoresRetiredChargeOnly() throws {
        let tmp = TempDir()
        XCTAssertTrue(BackupSettings(directory: tmp.url).wifiOnly())
        tmp.write(BackupSettings.fileName, #"{"wifiOnly":false,"chargeOnly":true}"#)
        XCTAssertFalse(BackupSettings(directory: tmp.url).wifiOnly())
        try BackupSettings(directory: tmp.url).save(wifiOnly: true)
        XCTAssertTrue(BackupSettings(directory: tmp.url).wifiOnly())
        tmp.write(BackupSettings.fileName, "garbage")
        XCTAssertTrue(BackupSettings(directory: tmp.url).wifiOnly(), "损坏回默认（仅 Wi‑Fi）")
    }

    // MARK: NotifyOnFailurePrefs

    /// #1262：缺失 / 损坏都按「关」。
    func testNotifyOnFailureDefaultsOffAndRoundTrips() throws {
        let tmp = TempDir()
        XCTAssertFalse(NotifyOnFailurePrefs(directory: tmp.url).enabled())
        try NotifyOnFailurePrefs(directory: tmp.url).setEnabled(true)
        XCTAssertTrue(NotifyOnFailurePrefs(directory: tmp.url).enabled())
        tmp.write(NotifyOnFailurePrefs.fileName, "[]")
        XCTAssertFalse(NotifyOnFailurePrefs(directory: tmp.url).enabled())
    }

    // MARK: OnboardedDesktopsStore

    func testOnboardedDesktopsOnlyGrowAndSurviveRestart() throws {
        let tmp = TempDir()
        let store = OnboardedDesktopsStore(directory: tmp.url)
        XCTAssertFalse(store.anyOnboarded())
        try store.markOnboarded("node-mac")
        try store.markOnboarded("node-win")
        try store.markOnboarded("node-mac")
        try store.markOnboarded("  ")
        let reopened = OnboardedDesktopsStore(directory: tmp.url)
        XCTAssertTrue(reopened.wasOnboarded("node-mac"))
        XCTAssertTrue(reopened.wasOnboarded("node-win"))
        XCTAssertFalse(reopened.wasOnboarded(""))
        XCTAssertFalse(reopened.wasOnboarded("node-new"))
    }

    /// 损坏 = 空集 = 按新电脑走 onboarding（失败关闭）。反证：损坏时返回「全部连过」，新电脑静默继承意图，红。
    func testOnboardedDesktopsCorruptMeansNewDesktop() {
        let tmp = TempDir()
        tmp.write(OnboardedDesktopsStore.fileName, #"{"nodeIds": "#)
        let store = OnboardedDesktopsStore(directory: tmp.url)
        XCTAssertFalse(store.wasOnboarded("node-mac"))
        XCTAssertFalse(store.anyOnboarded())
    }

    /// 标记不在就不读范围（读范围会触发一次性认领）。
    func testKnownDesktopDoesNotTouchScopeWhenNotOnboarded() throws {
        let tmp = TempDir()
        let store = OnboardedDesktopsStore(directory: tmp.url)
        var asked = false
        XCTAssertFalse(isKnownDesktop(store, daemonNodeId: "n", scopeNonEmpty: { asked = true; return true }))
        XCTAssertFalse(asked)
        try store.markOnboarded("n")
        XCTAssertTrue(isKnownDesktop(store, daemonNodeId: "n", scopeNonEmpty: { true }))
        XCTAssertFalse(isKnownDesktop(store, daemonNodeId: "n", scopeNonEmpty: { false }))
    }

    // MARK: Sentinel

    func testSentinelDecisionTable() {
        let h: Int64 = 60 * 60 * 1000
        let now: Int64 = 1_000 * h
        XCTAssertFalse(Sentinel.shouldNotify(SentinelState(lastReachableAt: 0, failedAttempts: 5), now: now), "从未可达 = 无结论")
        XCTAssertFalse(Sentinel.shouldNotify(SentinelState(lastReachableAt: now - 71 * h, failedAttempts: 5), now: now))
        XCTAssertFalse(Sentinel.shouldNotify(SentinelState(lastReachableAt: now - 73 * h, failedAttempts: 0), now: now), "手机自己没触发")
        XCTAssertTrue(Sentinel.shouldNotify(SentinelState(lastReachableAt: now - 73 * h, failedAttempts: 1), now: now))
        XCTAssertFalse(Sentinel.shouldNotify(SentinelState(lastReachableAt: now - 73 * h, failedAttempts: 1, lastNotifiedAt: now - 10 * h), now: now), "去重窗口")
    }

    func testSentinelStoreRoundTripAndReset() throws {
        let tmp = TempDir()
        try SentinelStore(directory: tmp.url).recordUnreachable()
        try SentinelStore(directory: tmp.url).recordUnreachable()
        XCTAssertEqual(SentinelStore(directory: tmp.url).load().failedAttempts, 2)
        try SentinelStore(directory: tmp.url).recordReachable(now: 42)
        XCTAssertEqual(SentinelStore(directory: tmp.url).load(), SentinelState(lastReachableAt: 42, failedAttempts: 0))
        try SentinelStore(directory: tmp.url).markNotified(now: 50)
        XCTAssertEqual(SentinelStore(directory: tmp.url).load().lastNotifiedAt, 50)
        tmp.write(SentinelStore.fileName, "x")
        XCTAssertEqual(SentinelStore(directory: tmp.url).load(), SentinelState())
    }

    // MARK: BackupScopeStore（MOB-92）

    /// macOS 选 3 个 → 断开 → 连 Windows 选 1 个 → 连回 macOS：拿到的还是 macOS 那 3 个。
    func testScopeIsPerDesktop() throws {
        let tmp = TempDir()
        try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").saveScope(selected: ["a", "b", "c"], allCurrent: ["a", "b", "c", "d"])
        try BackupScopeStore(directory: tmp.url, daemonNodeId: "win").saveScope(selected: ["d"], allCurrent: ["a", "b", "c", "d"])
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").selectedBucketIds(), ["a", "b", "c"])
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "win").selectedBucketIds(), ["d"])
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").knownBucketIds(), ["a", "b", "c", "d"])
    }

    /// nil = 从未保存过（不是「全部」）；空集是保存过的空范围。
    func testNeverSavedIsNilNotAll() throws {
        let tmp = TempDir()
        XCTAssertNil(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").selectedBucketIds())
        try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").saveScope(selected: [], allCurrent: ["a"])
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").selectedBucketIds(), [])
    }

    /// 未配对时存的全局范围：第一台来取的桌面复制认领一次并盖章，第二台新桌面不继承。
    /// 反证：去掉盖章，第二台也拿到 ["x"]，红。
    func testUnpairedScopeIsAdoptedOnceByTheFirstDesktop() throws {
        let tmp = TempDir()
        try BackupScopeStore(directory: tmp.url, daemonNodeId: nil).saveScope(selected: ["x"], allCurrent: ["x", "y"])
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: "first").selectedBucketIds(), ["x"])
        XCTAssertNil(try BackupScopeStore(directory: tmp.url, daemonNodeId: "second").selectedBucketIds())
        // 复制不是移动：全局那份原样留着。
        XCTAssertEqual(try BackupScopeStore(directory: tmp.url, daemonNodeId: nil).selectedBucketIds(), ["x"])
        XCTAssertTrue(tmp.read("backup_scope.json")?.contains(#""adopted_by":"first""#) ?? false)
    }

    func testAdoptionDecisionTable() {
        XCTAssertEqual(BackupScopeStore.decideAdoption(alreadyAdoptedBy: "a", legacyBuckets: ["x"]), .alreadyClaimed)
        XCTAssertEqual(BackupScopeStore.decideAdoption(alreadyAdoptedBy: nil, legacyBuckets: nil), .stampOnly)
        XCTAssertEqual(BackupScopeStore.decideAdoption(alreadyAdoptedBy: " ", legacyBuckets: []), .stampOnly)
        XCTAssertEqual(BackupScopeStore.decideAdoption(alreadyAdoptedBy: nil, legacyBuckets: ["x"]), .copyThenStamp)
    }

    func testCorruptScopeReadsAsNeverSaved() throws {
        let tmp = TempDir()
        tmp.write(BackupScopeStore.fileName(nodeId: "mac"), "{")
        XCTAssertNil(try BackupScopeStore(directory: tmp.url, daemonNodeId: "mac").selectedBucketIds())
    }
}
