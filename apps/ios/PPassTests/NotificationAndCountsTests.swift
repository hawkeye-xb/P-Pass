import PPassCore
import UserNotifications
import XCTest
@testable import PPass

/// #975 通知授权三态映射 + #973 首页计数读库失败 → UI 状态。
final class NotificationAndCountsTests: XCTestCase {
    typealias P = HomeProjection
    private struct Boom: Error {}

    // MARK: #975

    func test_system_status_maps_to_three_states() {
        XCTAssertEqual(NotificationAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationAuthorization(.denied), .denied)
        XCTAssertEqual(NotificationAuthorization(.authorized), .authorized)
        XCTAssertEqual(NotificationAuthorization(.provisional), .authorized)
        XCTAssertEqual(NotificationAuthorization(.ephemeral), .authorized)
    }

    func test_gate_never_posts_without_authorization_and_does_not_burn_the_notified_mark() {
        XCTAssertEqual(NotifyGate.decide(active: true, alreadyNotified: false, authorization: .authorized), .post)
        XCTAssertEqual(NotifyGate.decide(active: true, alreadyNotified: false, authorization: .notDetermined), .undeliverable)
        XCTAssertEqual(NotifyGate.decide(active: true, alreadyNotified: false, authorization: .denied), .undeliverable)
        XCTAssertEqual(NotifyGate.decide(active: true, alreadyNotified: true, authorization: .authorized), .alreadyNotified)
        XCTAssertEqual(NotifyGate.decide(active: false, alreadyNotified: true, authorization: .denied), .clear)
    }

    // MARK: #973

    private func readableFacts(pending: Int = 0) -> FlowFacts {
        FlowFacts(view: EngineSnapshot(state: .idle, pending: pending), confirmed: 10, inScopeTotal: 10)
    }

    func test_unreadable_counts_never_yield_all_safe_even_when_engine_says_nothing_pending() {
        // 反证组合：引擎视图已知且 pending=0、范围有值；账本读失败。旧实现落成 0 → done = n → allSafe。
        let ok = readableFacts().applying(counts: .success(OrderCounts(byState: [:], confirmed: 10, lastSuccessAt: 5,
                                                                      missingSourceUnacknowledged: 0, missingSourceAcknowledged: 0)))
        XCTAssertEqual(P.backupUiState(ok, noAlbums: false), .allSafe(ingested: 10), "对照：读得到时确实是 allSafe")

        let bad = readableFacts().applying(counts: .failure(Boom()))
        XCTAssertFalse(bad.countsReadable)
        XCTAssertEqual(P.backupUiState(bad, noAlbums: false), .idle)
        XCTAssertFalse(P.allDone(bad))
        XCTAssertNil(P.triplet(bad, scopeSaved: true), "没有三元组 → 状态行 / 诊断页拿不到「已备份 m 张」「上次成功」")
        XCTAssertEqual(P.heroRender(.full, nil, countsReadable: false), .countsUnreadable)
        XCTAssertNotEqual(P.statusLine(P.backupUiState(bad, noAlbums: false), pendingK: 0), .allSafe)
    }

    func test_unreadable_counts_do_not_raise_trouble_either() {
        // 占位 0 也不能被当成「0 张失败」；更不能据此触发 FailureNotifier（trouble 才会发通知）。
        let bad = readableFacts(pending: 3).applying(counts: .failure(Boom()))
        if case .trouble = P.backupUiState(bad, noAlbums: false) { XCTFail("读失败不是 trouble") }
    }

    func test_successful_counts_use_android_formula() {
        let c = OrderCounts(byState: [.failed: 2, .pending: 3, .transferring: 1, .skippedByUser: 4], confirmed: 9, lastSuccessAt: 77,
                            missingSourceUnacknowledged: 5, missingSourceAcknowledged: 6)
        let f = FlowFacts().applying(counts: .success(c))
        XCTAssertTrue(f.countsReadable)
        XCTAssertEqual(f.failed, 2)
        XCTAssertEqual(f.unfinished, 6)
        XCTAssertEqual(f.confirmed, 9)
        XCTAssertEqual(f.lastSuccessAt, 77)
        XCTAssertEqual(f.skippedByUser, 4)
        XCTAssertEqual(f.missingSourceUnacknowledged, 5)
        XCTAssertEqual(f.missingSourceAcknowledged, 6)
    }
}
