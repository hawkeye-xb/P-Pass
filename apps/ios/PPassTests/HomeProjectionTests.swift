import PPassCore
import XCTest
@testable import PPass

/// 首页裁决的契约测试——逐条移植 Android：
/// ui/BackupStatusTest、ui/UI16HeroGreenGateTest、backup/flow/W5EngineViewUiTest、ARCH14UiProjectionTest 的纯函数部分。
final class HomeProjectionTests: XCTestCase {
    typealias P = HomeProjection

    // MARK: BackupStatusTest

    func test_pending_over_zero_never_yields_all_safe() {
        XCTAssertEqual(P.statusLine(.allSafe(ingested: 3), pendingK: 54), .pending(54))
        XCTAssertEqual(P.statusLine(.idle, pendingK: 1), .pending(1))
        XCTAssertEqual(P.statusLine(.allSafe(ingested: 3), pendingK: 0), .allSafe)
    }

    func test_working_and_trouble_outrank_pending() {
        XCTAssertEqual(P.statusLine(.sending(done: 2, total: 9, currentFile: "a"), pendingK: 54), .working)
        XCTAssertEqual(P.statusLine(.trouble("x"), pendingK: 54), .trouble)
    }

    func test_epoch_zero_yields_never_not_a_date() {
        XCTAssertEqual(P.lastSuccess(ts: 0, now: 1_000_000), .never)
        XCTAssertEqual(P.lastSuccess(ts: -1, now: 1_000_000), .never)
    }

    func test_recent_timestamps_humanize() {
        let now: Int64 = 10_000_000_000
        XCTAssertEqual(P.lastSuccess(ts: now - 30_000, now: now), .justNow)
        XCTAssertEqual(P.lastSuccess(ts: now - 5 * 60_000, now: now), .minutesAgo(5))
        XCTAssertEqual(P.lastSuccess(ts: now - 3 * 3_600_000, now: now), .hoursAgo(3))
        XCTAssertEqual(P.lastSuccess(ts: now - 2 * 86_400_000, now: now), .at(now - 2 * 86_400_000))
    }

    // MARK: UI16HeroGreenGateTest（基线 n=10, confirmed=10）

    private let healthy = P.tripletOf(n: 10, confirmed: 10, lastSuccessAt: 1)

    func test_g1_partial_or_no_access_is_never_green() {
        XCTAssertFalse(P.heroNumberIsSafe(.partial, healthy, pairingLost: false))
        XCTAssertFalse(P.heroNumberIsSafe(.none, healthy, pairingLost: false))
    }

    func test_g2_to_g5_each_veto_green() {
        XCTAssertFalse(P.heroNumberIsSafe(.full, nil, pairingLost: false))
        XCTAssertFalse(P.heroNumberIsSafe(.full, healthy, pairingLost: true))
        XCTAssertFalse(P.heroNumberIsSafe(.full, P.tripletOf(n: 10, confirmed: 10, lastSuccessAt: 1, hasFailedNeedsUser: true), pairingLost: false))
        XCTAssertFalse(P.heroNumberIsSafe(.full, P.tripletOf(n: 10, confirmed: 10, lastSuccessAt: 1, pausedByUser: true), pairingLost: false))
    }

    func test_healthy_is_green_triplet_and_all_safe() {
        XCTAssertTrue(P.heroNumberIsSafe(.full, healthy, pairingLost: false))
        XCTAssertEqual(P.heroRender(.full, healthy), .triplet)
        XCTAssertEqual(healthy.m, 10)
        XCTAssertTrue(P.allSafeTextAllowed(.full, healthy, pairingLost: false, missingSource: 0))
    }

    func test_h_c_more_confirmed_than_n_is_unreconciled_and_clamped() {
        let t = P.tripletOf(n: 10, confirmed: 51, lastSuccessAt: 1)
        XCTAssertEqual(P.heroRender(.full, t), .unreconciled)
        XCTAssertEqual(t.m, 10)
        XCTAssertEqual(t.confirmedRaw, 51)
        XCTAssertFalse(P.allSafeTextAllowed(.full, t, pairingLost: false, missingSource: 0))
    }

    /// MOB-02 / MOB-94：权限不全 → 引导卡顶替数字（不渲染任何数，所以不可能盖「都存好了」的章）。
    func test_h_a_h_b_access_blocked_and_unreadable() {
        XCTAssertEqual(P.heroRender(.none, healthy), .accessBlocked)
        XCTAssertEqual(P.heroRender(.partial, healthy), .accessBlocked)
        XCTAssertEqual(P.heroRender(.full, nil), .unreadable)
        // 范围从未保存（没选相册）≠ 相册数量读不到：前者说「未选相册」，后者才说读取失败。
        XCTAssertEqual(P.heroRender(.full, nil, scopeSaved: false), .noAlbums)
        XCTAssertEqual(P.heroRender(.full, nil, scopeSaved: true), .unreadable)
        XCTAssertEqual(P.heroRender(.none, nil, scopeSaved: false), .accessBlocked, "权限不全仍压过一切")
        XCTAssertEqual(P.heroRender(.full, nil, countsReadable: false, scopeSaved: false), .countsUnreadable)
        XCTAssertFalse(P.allSafeTextAllowed(.partial, healthy, pairingLost: false, missingSource: 0))
    }

    func test_rule_s_each_open_fact_vetoes_all_safe_text() {
        XCTAssertFalse(P.allSafeTextAllowed(.full, healthy, pairingLost: true, missingSource: 0))
        XCTAssertFalse(P.allSafeTextAllowed(.full, healthy, pairingLost: false, missingSource: 1))
        let skipped = P.tripletOf(n: 10, confirmed: 10, lastSuccessAt: 1, skippedByUser: 3)
        XCTAssertFalse(P.allSafeTextAllowed(.full, skipped, pairingLost: false, missingSource: 0))
    }

    func test_device_combos_lost_with_failures_and_paused() {
        let failed = P.tripletOf(n: 10, confirmed: 10, lastSuccessAt: 1, hasFailedNeedsUser: true)
        XCTAssertFalse(P.heroNumberIsSafe(.full, failed, pairingLost: true))
        XCTAssertFalse(P.allSafeTextAllowed(.full, failed, pairingLost: true, missingSource: 0))
        let paused = P.tripletOf(n: 23, confirmed: 23, lastSuccessAt: 1, pausedByUser: true)
        XCTAssertFalse(P.heroNumberIsSafe(.full, paused, pairingLost: false))
        XCTAssertFalse(P.allSafeTextAllowed(.full, paused, pairingLost: false, missingSource: 0))
    }

    // MARK: W5EngineViewUiTest

    private func facts(_ v: EngineSnapshot?, n: Int64 = 10, confirmed: Int64 = 3, failed: Int64 = 0) -> FlowFacts {
        FlowFacts(view: v, confirmed: confirmed, inScopeTotal: n, failed: failed)
    }

    func test_global_states_map_to_ui_states() {
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .paused)), noAlbums: false), .paused)
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .running)), noAlbums: false), .preparing)
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .running, pending: 4, doneThisRound: 2, currentFileName: "IMG_7.jpg")), noAlbums: false),
                       .sending(done: 3, total: 6, currentFile: "IMG_7.jpg"))
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .waiting, waitReason: .desktopUnreachable)), noAlbums: false),
                       .waiting(.desktopUnreachable))
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .idle, pending: 5)), noAlbums: false), .idle)
    }

    func test_status_lines_for_new_states() {
        XCTAssertEqual(P.statusLine(.preparing, pendingK: 3), .working)
        XCTAssertEqual(P.statusLine(.paused, pendingK: 3), .paused)
        XCTAssertEqual(P.statusLine(.waiting(.wifi), pendingK: 3), .waiting)
    }

    func test_waiting_outranks_failures_but_not_paired_does_not() {
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .waiting, waitReason: .battery), failed: 2), noAlbums: false), .waiting(.battery))
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .waiting, waitReason: .notPaired), failed: 2), noAlbums: false), .trouble("flow.failed=2"))
    }

    func test_hero_action_pause_resume_and_hidden() {
        XCTAssertEqual(P.heroAction(.sending(done: 1, total: 2, currentFile: "a"), pairingLost: false), .pause)
        XCTAssertEqual(P.heroAction(.preparing, pairingLost: false), .pause)
        XCTAssertEqual(P.heroAction(.paused, pairingLost: false), .resume)
        XCTAssertNil(P.heroAction(.idle, pairingLost: false))
        XCTAssertNil(P.heroAction(.paused, pairingLost: true))
    }

    func test_null_view_falls_back_to_n_minus_m_and_is_not_all_done() {
        let f = facts(nil, n: 10, confirmed: 3)
        XCTAssertEqual(P.triplet(f, scopeSaved: true)?.k, 7)
        XCTAssertFalse(P.allDone(f))
        XCTAssertEqual(P.backupUiState(f, noAlbums: false), .idle)
    }

    func test_all_done_needs_zero_pending_and_something_done() {
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .idle, pending: 0)), noAlbums: false), .allSafe(ingested: 10))
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .idle, pending: 0), n: 0, confirmed: 0), noAlbums: false), .idle)
    }

    func test_no_albums_is_its_own_state_not_all_safe() {
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .idle, pending: 0)), noAlbums: true), .noAlbums)
        XCTAssertNil(P.triplet(facts(EngineSnapshot()), scopeSaved: false))
    }

    // MARK: ARCH14UiProjectionTest

    func test_round_ordinal() {
        XCTAssertTrue(P.roundOrdinal(doneThisRound: 0, pending: 0) == (1, 1))
        XCTAssertTrue(P.roundOrdinal(doneThisRound: 2, pending: 0) == (3, 3))
        XCTAssertTrue(P.roundOrdinal(doneThisRound: 2, pending: 5) == (3, 7))
        XCTAssertEqual(P.backupUiState(facts(EngineSnapshot(state: .running, pending: 0, doneThisRound: 10, currentFileName: "x")), noAlbums: false),
                       .sending(done: 11, total: 11, currentFile: "x"))
    }

    func test_every_wait_reason_has_copy_in_both_languages() {
        for r in WaitReason.allCases {
            let key = P.waitTextKey(r)
            for lang in ["en", "zh-Hans"] {
                let b = try! XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)))
                let s = b.localizedString(forKey: key, value: "\u{1}", table: "IOS")
                let t = b.localizedString(forKey: key, value: "\u{1}", table: nil)
                XCTAssertTrue(s != "\u{1}" || t != "\u{1}", "\(lang) 缺 \(key)（\(r.rawValue)）")
            }
        }
    }
}
