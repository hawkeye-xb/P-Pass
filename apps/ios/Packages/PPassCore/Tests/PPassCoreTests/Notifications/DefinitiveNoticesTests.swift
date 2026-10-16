// #981：失败通知的触发集合与去重——对位 Android `DefinitiveEventNoticesTest`。
// 只发三类确定事件（配对失效 / 相册权限变差 / 后台刷新被关），「备份出问题」不发（#418）；去重状态落盘。
import Foundation
import XCTest
@testable import PPassCore

final class DefinitiveNoticesTests: XCTestCase {
    private func facts(epoch: String? = "e1", lost: Bool = false, media: MediaAccessTier = .full,
                       requested: Bool = true, refresh: BackgroundRefreshAvailability = .available) -> DefinitiveFacts {
        DefinitiveFacts(pairingEpoch: epoch, pairingLost: lost, mediaAccess: media, backgroundRequested: requested, backgroundRefresh: refresh)
    }

    private func decide(_ prev: DefinitiveNoticeState, _ f: DefinitiveFacts, deliverable: Bool = true) -> DefinitiveDecision {
        decideDefinitiveNotices(prev: prev, facts: f, deliverable: deliverable)
    }

    // MARK: 触发集合

    func testOnlyTheThreeDefinitiveEventsExist() {
        // 「备份出问题」（run_failed / Trouble）不在集合里：Android 因 #418 故意不发，iOS 不许多发。
        XCTAssertEqual(Set(NoticeEvent.allCases), [.pairingLost, .mediaAccessRevoked, .backgroundStopped])
    }

    // MARK: 配对失效（去重键 = epoch）

    func testPairingLostPostsOnceForAnEpoch() {
        let d1 = decide(DefinitiveNoticeState(), facts(lost: true))
        XCTAssertEqual(d1.post, [.pairingLost])
        XCTAssertEqual(d1.next.notifiedLostEpoch, "e1")
        let d2 = decide(d1.next, facts(lost: true))
        XCTAssertEqual(d2.post, [], "同一个配对代号只发一次")
    }

    func testIsLostFalseAfterRestartIsNotARecovery() {
        let posted = decide(DefinitiveNoticeState(), facts(lost: true)).next
        // 进程重启后 lost 标记还在盘上；就算读到 false 也不算恢复，更不复位。
        let d = decide(posted, facts(lost: false))
        XCTAssertEqual(d.next.notifiedLostEpoch, "e1")
        XCTAssertTrue(d.cancel.isEmpty)
        XCTAssertEqual(decide(d.next, facts(lost: true)).post, [], "重启后又读到 lost 也不重发")
    }

    func testNewEpochResetsAndNotifiesAgain() {
        let posted = decide(DefinitiveNoticeState(), facts(lost: true)).next
        let rescanned = decide(posted, facts(epoch: "e2", lost: false))
        XCTAssertEqual(rescanned.cancel, [.pairingLost], "重新扫码：撤掉还挂着的旧通知")
        XCTAssertNil(rescanned.next.notifiedLostEpoch)
        XCTAssertEqual(decide(rescanned.next, facts(epoch: "e2", lost: true)).post, [.pairingLost])
    }

    func testNoPairingResetsAndNeverPosts() {
        let posted = decide(DefinitiveNoticeState(), facts(lost: true)).next
        let d = decide(posted, facts(epoch: nil, lost: true))
        XCTAssertEqual(d.post, [])
        XCTAssertEqual(d.cancel, [.pairingLost])
        XCTAssertNil(d.next.notifiedLostEpoch)
    }

    // MARK: 相册权限（变差才发，回到完整复位，无基线只记）

    func testFirstEvaluationOnlyRecordsTheMediaBaseline() {
        let d = decide(DefinitiveNoticeState(), facts(media: .none))
        XCTAssertEqual(d.post, [], "新装 / 升级上来：没有「上次」，只记基线不发")
        XCTAssertEqual(d.next.lastMediaAccess, "none")
    }

    func testMediaAccessGettingWorseNotifies() {
        let full = decide(DefinitiveNoticeState(), facts(media: .full)).next
        let partial = decide(full, facts(media: .partial))
        XCTAssertEqual(partial.post, [.mediaAccessRevoked(now: .partial)])
        let none = decide(partial.next, facts(media: .none))
        XCTAssertEqual(none.post, [.mediaAccessRevoked(now: .none)])
        XCTAssertEqual(decide(none.next, facts(media: .none)).post, [], "没再变差就不重发")
    }

    func testMediaAccessImprovingDoesNotNotifyAndFullCancels() {
        let none = DefinitiveNoticeState(lastMediaAccess: "none")
        XCTAssertEqual(decide(none, facts(media: .partial)).post, [])
        let back = decide(DefinitiveNoticeState(lastMediaAccess: "partial"), facts(media: .full))
        XCTAssertEqual(back.post, [])
        XCTAssertEqual(back.cancel, [.mediaAccessRevoked])
    }

    func testMediaAccessWorseWhileUnpairedOnlyRecords() {
        let d = decide(DefinitiveNoticeState(lastMediaAccess: "full"), facts(epoch: nil, media: .none))
        XCTAssertEqual(d.post, [], "没配对：没有要备份的东西")
        XCTAssertEqual(d.next.lastMediaAccess, "none")
    }

    // MARK: 后台被停（iOS 对位：「后台 App 刷新」从可用变成不可用）

    func testFirstEvaluationOnlyRecordsTheRefreshBaseline() {
        let d = decide(DefinitiveNoticeState(), facts(refresh: .denied))
        XCTAssertEqual(d.post, [])
        XCTAssertEqual(d.next.lastBackgroundRefreshAvailable, false)
    }

    func testBackgroundRefreshTurnedOffNotifiesWhenTheUserWantsBackgroundBackup() {
        let on = decide(DefinitiveNoticeState(), facts()).next
        let off = decide(on, facts(refresh: .denied))
        XCTAssertEqual(off.post, [.backgroundRefreshOff(restricted: false)])
        XCTAssertEqual(decide(off.next, facts(refresh: .denied)).post, [], "已经是关的：不重发")
        let restricted = decide(on, facts(refresh: .restricted))
        XCTAssertEqual(restricted.post, [.backgroundRefreshOff(restricted: true)], "被屏幕使用时间 / 设备管理限制：用户自己改不了，文案不同")
    }

    func testBackgroundRefreshOffIsSilentWhenTheUserNeverAskedForBackgroundBackup() {
        let on = decide(DefinitiveNoticeState(), facts(requested: false)).next
        XCTAssertEqual(decide(on, facts(requested: false, refresh: .denied)).post, [])
    }

    func testBackgroundRefreshBackOnCancelsAndRearms() {
        let off = DefinitiveNoticeState(lastBackgroundRefreshAvailable: false)
        let back = decide(off, facts())
        XCTAssertEqual(back.cancel, [.backgroundStopped])
        XCTAssertEqual(decide(back.next, facts(refresh: .denied)).post, [.backgroundRefreshOff(restricted: false)], "恢复后再关：再发")
    }

    func testBackgroundRefreshOffWhileUnpairedOnlyRecords() {
        let d = decide(DefinitiveNoticeState(lastBackgroundRefreshAvailable: true), facts(epoch: nil, refresh: .denied))
        XCTAssertEqual(d.post, [])
        XCTAssertEqual(d.next.lastBackgroundRefreshAvailable, false)
    }

    // MARK: 开关 / 系统授权：只挡「发出去」，状态照常推进，之后打开也不补发（同 Android）

    func testUndeliverableSuppressesPostButAdvancesState() {
        let prev = DefinitiveNoticeState(lastMediaAccess: "full", lastBackgroundRefreshAvailable: true)
        let all = facts(lost: true, media: .none, refresh: .denied)
        let blocked = decide(prev, all, deliverable: false)
        XCTAssertEqual(blocked.post, [])
        XCTAssertEqual(Set(blocked.undeliverable), [.pairingLost, .mediaAccessRevoked, .backgroundStopped])
        XCTAssertEqual(blocked.next, DefinitiveNoticeState(notifiedLostEpoch: "e1", lastMediaAccess: "none", lastBackgroundRefreshAvailable: false))
        // 打开开关 / 授权之后：同一状况不补发。
        let open = decide(blocked.next, all, deliverable: true)
        XCTAssertEqual(open.post, [])
        XCTAssertTrue(open.undeliverable.isEmpty)
    }

    func testUndeliverableStillAdvancesRecoveryAndBaselines() {
        let d = decide(DefinitiveNoticeState(notifiedLostEpoch: "e1", lastMediaAccess: "partial"), facts(epoch: "e2", media: .full), deliverable: false)
        XCTAssertEqual(d.cancel, [.pairingLost, .mediaAccessRevoked])
        XCTAssertNil(d.next.notifiedLostEpoch)
        XCTAssertEqual(d.next.lastMediaAccess, "full")
    }

    // MARK: 落盘

    func testStatePersistsAcrossProcessRestarts() throws {
        let tmp = TempDir()
        let first = try DefinitiveEventMonitor.evaluate(store: DefinitiveNoticeStore(directory: tmp.url), facts: facts(lost: true), deliverable: true)
        XCTAssertEqual(first.post, [.pairingLost])
        // 重启 = 全新 store 实例读同一个目录：不重发。反证：换一个空目录（等价于只在内存里去重）就会重发。
        let restarted = try DefinitiveEventMonitor.evaluate(store: DefinitiveNoticeStore(directory: tmp.url), facts: facts(lost: true), deliverable: true)
        XCTAssertEqual(restarted.post, [])
        let inMemoryOnly = try DefinitiveEventMonitor.evaluate(store: DefinitiveNoticeStore(directory: TempDir().url), facts: facts(lost: true), deliverable: true)
        XCTAssertEqual(inMemoryOnly.post, [.pairingLost])
    }

    func testStoreUsesAndroidFileNameAndFieldNames() throws {
        let tmp = TempDir()
        let store = DefinitiveNoticeStore(directory: tmp.url)
        try store.save(DefinitiveNoticeState(notifiedLostEpoch: "e1", lastMediaAccess: "partial", lastBackgroundRefreshAvailable: false))
        XCTAssertEqual(DefinitiveNoticeStore.fileName, "definitive_notices.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.url.appendingPathComponent("definitive_notices.json"))) as? [String: Any]
        XCTAssertEqual(json?["notifiedLostEpoch"] as? String, "e1")
        XCTAssertEqual(json?["lastMediaAccess"] as? String, "partial")
        XCTAssertEqual(json?["lastBackgroundRefreshAvailable"] as? Bool, false)
    }

    func testMissingFileIsAFreshBaselineSilently() {
        let logger = RecordingLogger()
        XCTAssertEqual(DefinitiveNoticeStore(directory: TempDir().url, logger: logger).load(), DefinitiveNoticeState())
        XCTAssertTrue(logger.lines.isEmpty)
    }

    func testCorruptFileFallsBackToBaselineAndSaysSo() {
        let tmp = TempDir()
        tmp.write(DefinitiveNoticeStore.fileName, "{not json")
        let logger = RecordingLogger()
        XCTAssertEqual(DefinitiveNoticeStore(directory: tmp.url, logger: logger).load(), DefinitiveNoticeState())
        XCTAssertFalse(logger.lines.isEmpty, "损坏不许静默")
    }

    func testSaveFailureSurfaces() {
        // 去重状态写不下去就必须抛：吞掉会让下一轮重发。目录位置被一个文件占着，写必败。
        let tmp = TempDir()
        let blocker = tmp.url.appendingPathComponent("blocked")
        try! Data().write(to: blocker)
        XCTAssertThrowsError(try DefinitiveNoticeStore(directory: blocker).save(DefinitiveNoticeState()))
    }
}
