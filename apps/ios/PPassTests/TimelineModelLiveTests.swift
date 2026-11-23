import Foundation
import PPassCore
import UIKit
import XCTest
@testable import PPass

/// 照片页实时刷新（#963，对位 Android SYNC-06 holder 的刷新语义）。
@MainActor
final class TimelineModelLiveTests: XCTestCase {
    private func item(_ n: Int) -> TimelineItem {
        TimelineItem(id: String(format: "%064x", n), takenAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(n)), isVideo: false,
                     width: nil, height: nil, bytes: nil, isMine: nil)
    }

    /// 可控的时间线：每次 page 调用按顺序取一个结果；`hold` 让调用挂起直到 `release()`。
    private final class Source: TimelineSource, @unchecked Sendable {
        enum Step { case page([Int], next: String?), fail }
        let lock = NSLock()
        var steps: [Step]
        var calls: [String?] = []
        var holding = false
        /// 只挂起第 n 次调用（从 1 数）；0 = 不按序号挂。
        var holdOnly = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        init(_ steps: [Step]) { self.steps = steps }

        struct Boom: Error {}
        func page(cursor: String?, reason: PPass.TimelinePageReason) async throws -> PPass.TimelinePage {
            lock.lock()
            calls.append(cursor)
            let step = steps.isEmpty ? Step.fail : (steps.count > 1 ? steps.removeFirst() : steps[0])
            let hold = holding && (holdOnly == 0 || holdOnly == calls.count)
            lock.unlock()
            if hold { await withCheckedContinuation { c in lock.lock(); waiters.append(c); lock.unlock() } }
            switch step {
            case .fail: throw Boom()
            case .page(let ns, let next):
                let items = ns.map { n in TimelineItem(id: String(format: "%064x", n), takenAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(n)),
                                                       isVideo: false, width: nil, height: nil, bytes: nil, isMine: nil) }
                return PPass.TimelinePage(items: items, nextCursor: next)
            }
        }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        func hold(only n: Int = 0) { lock.lock(); holding = true; holdOnly = n; lock.unlock() }
        func release() {
            lock.lock(); holding = false; let w = waiters; waiters = []; lock.unlock()
            w.forEach { $0.resume() }
        }
        func thumbnail(_ item: TimelineItem, large: Bool) async throws -> UIImage { UIImage() }
        func cachedOriginal(_ item: TimelineItem) -> URL? { nil }
        func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL { throw Boom() }
    }

    @MainActor private final class Feed: TimelineLiveFeed {
        var handlers: [UUID: @MainActor (TimelineLiveEvent) -> Void] = [:]
        var retries = 0
        func observe(_ handler: @escaping @MainActor (TimelineLiveEvent) -> Void) -> UUID {
            let t = UUID(); handlers[t] = handler; handler(.state(TimelineLiveState())); return t
        }
        func remove(_ token: UUID) { handlers[token] = nil }
        func retry() { retries += 1 }
        func emit(_ e: TimelineLiveEvent) { handlers.values.forEach { $0(e) } }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if cond() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("timed out waiting for \(what)")
    }

    private func loaded(_ source: Source) async -> TimelineModel {
        let m = TimelineModel()
        m.bind(source)
        await m.loadFirst()
        return m
    }

    func testSignalReplacesFirstPageWithoutEmptyingTheGridFirst() async {
        let s = Source([.page([3, 2, 1], next: "c1"), .page([4, 3, 2, 1], next: "c1")])
        let m = await loaded(s)
        XCTAssertEqual(m.items.map(\.id), [3, 2, 1].map { item($0).id })
        s.hold()
        let t = Task { await m.refreshFromSignal() }
        await waitUntil("刷新请求发出") { s.callCount == 2 }
        XCTAssertEqual(m.items.count, 3, "结果回来之前旧内容原样在（不闪、不丢滚动位置）")
        s.release()
        await t.value
        XCTAssertEqual(m.items.map(\.id), [4, 3, 2, 1].map { item($0).id }, "新照片出现，无需手动刷新")
    }

    func testBurstOfSignalsCoalescesIntoAtMostOneFollowUp() async {
        let s = Source([.page([1], next: nil), .page([2, 1], next: nil)])
        let m = await loaded(s)
        s.hold()
        let first = Task { await m.refreshFromSignal() }
        await waitUntil("在飞") { s.callCount == 2 }
        let burst = (0..<8).map { _ in Task { await m.refreshFromSignal() } } // 一批备份连发 8 个信号
        try? await Task.sleep(nanoseconds: 50_000_000)
        s.release()
        for t in burst { await t.value }
        await first.value
        XCTAssertEqual(s.callCount, 3, "在飞的 1 次 + 补刷 1 次，不是 9 次")
        XCTAssertEqual(m.items.count, 2)
    }

    func testFailedRefreshKeepsItemsAndShowsNoError() async {
        let s = Source([.page([2, 1], next: nil), .fail])
        let m = await loaded(s)
        await m.refreshFromSignal()
        XCTAssertEqual(m.items.count, 2)
        XCTAssertNil(m.error, "信号触发的刷新失败不亮错误，等下一次信号 / 兜底")
    }

    func testSuccessfulRefreshClearsAnEarlierLoadError() async {
        let s = Source([.fail, .page([1], next: nil)])
        let m = await loaded(s)
        XCTAssertNotNil(m.error)
        XCTAssertTrue(m.items.isEmpty)
        await m.refreshFromSignal()
        XCTAssertNil(m.error, "订阅恢复后「连不上」要能自己消掉")
        XCTAssertEqual(m.items.count, 1)
    }

    func testFallbackOnlyPrependsUnknownItemsAndKeepsPagingCursor() async {
        let s = Source([.page([3, 2], next: "c1"), .page([9, 3], next: "zzz"), .page([1], next: nil)])
        let m = await loaded(s)
        await m.refreshFallback()
        XCTAssertEqual(m.items.map(\.id), [9, 3, 2].map { item($0).id }, "只追加没见过的，已有的不动")
        await m.loadMore()
        XCTAssertEqual(s.calls.last ?? nil, "c1", "兜底不动翻页游标")
    }

    func testPagingResultFromAReplacedSnapshotIsDropped() async {
        // 第 2 次调用 = 翻页（旧游标 c1），挂着；这期间整页刷新换了新快照；翻页回来时必须丢弃，
        // 否则旧游标的下一页会接到新快照后面（重复 / 错位）。
        let s = Source([.page([5, 4], next: "c1"), .page([3, 2], next: nil), .page([6, 5, 4], next: "c9")])
        let m = await loaded(s)
        s.hold(only: 2)
        let paging = Task { await m.loadMore() }
        await waitUntil("翻页在飞") { s.callCount == 2 }
        await m.refreshFromSignal()
        XCTAssertEqual(m.items.count, 3)
        s.release()
        await paging.value
        XCTAssertEqual(m.items.map(\.id), [6, 5, 4].map { item($0).id }, "旧快照的翻页结果被丢弃")
    }

    func testPagingFailureWithItemsStopsQuietly() async {
        let s = Source([.page([2, 1], next: "c1"), .fail])
        let m = await loaded(s)
        await m.loadMore()
        XCTAssertNil(m.error, "对位 Android：已有内容时翻页失败静默停住，不挡住照片")
        XCTAssertEqual(m.items.count, 2)
    }

    // MARK: 接线

    func testFeedInvalidatedTriggersRefreshAndDetachStopsIt() async {
        let s = Source([.page([1], next: nil), .page([2, 1], next: nil), .page([3, 2, 1], next: nil)])
        let feed = Feed()
        let m = await loaded(s)
        m.attach(feed)
        feed.emit(.invalidated)
        await waitUntil("信号 → 刷新") { m.items.count == 2 }
        m.detach()
        feed.emit(.invalidated) // 反证：注销后的信号不得再刷新
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(s.callCount, 2)
    }

    func testFeedStateReachesTheModelAndRetryGoesBack() async {
        let s = Source([.page([1], next: nil)])
        let feed = Feed()
        let m = await loaded(s)
        m.attach(feed)
        var st = TimelineLiveState(); st.exhausted = true; st.hadFailure = true
        feed.emit(.state(st))
        XCTAssertTrue(TimelineLiveChrome(state: m.live, pairingLost: false).showExhaustedRetry)
        m.retryLive()
        XCTAssertEqual(feed.retries, 1)
    }

    // MARK: 唯一连接状态（#1904，对位 Android #1883）

    /// 初始整页加载失败留下的 error 不会自己消失；订阅连上后必须补拉一次整页，成功即清 error。
    func testConnectedStateAfterFailedFirstLoadRefetchesAndClearsTheError() async {
        let s = Source([.fail, .page([1, 2], next: nil)])
        let feed = Feed()
        let m = await loaded(s)
        XCTAssertNotNil(m.error, "前提：首屏加载失败留下错误")
        XCTAssertTrue(m.items.isEmpty)
        m.attach(feed)
        var st = TimelineLiveState(); st.connected = true
        feed.emit(.state(st))
        await waitUntil("连上后补拉首页") { m.items.count == 2 }
        XCTAssertNil(m.error, "补拉成功后「连不上」要能自己消掉")
        XCTAssertEqual(s.callCount, 2, "只补一次整页")
    }

    /// 反证面：没连上（重连中 / 断开）不补拉——只剩旧错误时不能凭空变成「连上了」。
    func testNotConnectedStateDoesNotRefetch() async {
        let s = Source([.fail, .page([1], next: nil)])
        let feed = Feed()
        let m = await loaded(s)
        m.attach(feed)
        var st = TimelineLiveState(); st.hadFailure = true
        feed.emit(.state(st))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s.callCount, 1, "重连中不补拉")
        XCTAssertNotNil(m.error)
    }

    // MARK: 存储电脑详情卡（#1904，对位 Android #1883 `storageDetailLines`）

    /// 只有真的连上才说「已连接」；其余三档一律「未连接 · 最近同步 X」。反证：改回「非配对失效一律已连接」即红。
    func testStorageDetailLinesOnlyClaimConnectedWhenActuallyConnected() {
        let paired: Int64 = 1_760_000_000_000
        for status in [ConnectionState.Status.reconnecting, .offline, .unknown] {
            let lines = storageDetailLines(status: status, pairedAtMs: paired)
            XCTAssertEqual(lines.statusKey, "storage_detail_offline", "\(status) 不得说已连接")
            XCTAssertTrue(lines.takesLastSuccess)
            XCTAssertTrue(lines.showPairedLine, "\(status) 配对日期有出处：第二行照常")
        }
        let connected = storageDetailLines(status: .connected, pairedAtMs: paired)
        XCTAssertEqual(connected.statusKey, "storage_detail_connected")
        XCTAssertNotEqual(connected.statusKey, "storage_detail_offline")
    }

    /// 配对已失效：正文只有单行「配对已失效」，不拼「配对 X · 已备份 N 张」（同一张卡自相矛盾）。
    func testStorageDetailLinesPairingLostIsSingleLine() {
        let lines = storageDetailLines(status: .pairingLost, pairedAtMs: 1_760_000_000_000)
        XCTAssertEqual(lines.statusKey, "storage_detail_lost")
        XCTAssertFalse(lines.takesLastSuccess, "「配对已失效」不带最近同步参数")
        XCTAssertFalse(lines.showPairedLine, "不得再拼第二行")
    }

    func testStorageDetailBodyRendersTheDecidedLines() {
        let paired: Int64 = 1_760_000_000_000
        let lost = storageDetailBody(ConnectionState(status: .pairingLost), lastSuccessAt: nil,
                                     pairedAtMs: paired, confirmedCount: 6)
        XCTAssertEqual(lost, L.s("storage_detail_lost"))
        XCTAssertFalse(lost.contains("\n"), "配对失效只有一行")

        let offline = storageDetailBody(ConnectionState(status: .offline), lastSuccessAt: nil,
                                        pairedAtMs: paired, confirmedCount: 6)
        let firstLine = offline.components(separatedBy: "\n")[0]
        XCTAssertEqual(firstLine, L.f("storage_detail_offline", L.s("last_success_never")),
                       "断开时只说「未连接 · 最近同步 X」")
        XCTAssertEqual(offline.components(separatedBy: "\n").count, 2, "配对日期有出处：第二行照常")

        let unknownNoPairedAt = storageDetailBody(ConnectionState(status: .unknown), lastSuccessAt: nil,
                                                  pairedAtMs: nil, confirmedCount: 0)
        XCTAssertEqual(unknownNoPairedAt.components(separatedBy: "\n").count, 1, "配对日期未知：不硬凑第二行")
        XCTAssertTrue(unknownNoPairedAt.hasPrefix(L.f("storage_detail_offline", L.s("last_success_never"))))

        let connected = storageDetailBody(ConnectionState(status: .connected), lastSuccessAt: nil,
                                          pairedAtMs: paired, confirmedCount: 6)
        XCTAssertTrue(connected.hasPrefix(L.f("storage_detail_connected", L.s("last_success_never"))))
    }

    /// 状态点颜色跟正文同一份状态：绿=连上、红=配对失效、琥珀=重连中、灰=断开/未知。
    func testStorageDetailDotColorFollowsTheUnifiedStatus() {
        XCTAssertTrue(UIColor(storageDetailDotColor(.connected)).isEqual(UIColor(PPColor.safe)))
        XCTAssertTrue(UIColor(storageDetailDotColor(.pairingLost)).isEqual(UIColor(PPColor.act)))
        XCTAssertTrue(UIColor(storageDetailDotColor(.reconnecting)).isEqual(UIColor(PPColor.waiting)))
        XCTAssertTrue(UIColor(storageDetailDotColor(.offline)).isEqual(UIColor(PPColor.idle)))
        XCTAssertTrue(UIColor(storageDetailDotColor(.unknown)).isEqual(UIColor(PPColor.idle)))
    }

    /// 源文本接线断言（对位 Android UI17 的做法）：两个页面真的消费唯一状态，而不是留着旧的二元判断。
    /// 只钉纯函数映射、正文不用它，这套断言会红（Android #1883 评审抓到的正是这种「接线没断」）。
    func testStorageDetailAndPhotosScreensReadTheUnifiedConnection() throws {
        let diag = try String(contentsOf: RepoPaths.root.appendingPathComponent(
            "apps/ios/PPass/Diagnostics/DiagnosticsScreen.swift"), encoding: .utf8)
        let photos = try String(contentsOf: RepoPaths.root.appendingPathComponent(
            "apps/ios/PPass/Photos/PhotosScreen.swift"), encoding: .utf8)

        XCTAssertTrue(diag.contains("storageDetailBody(app.connection"), "详情页正文必须读 app.connection")
        XCTAssertTrue(diag.contains("storageDetailDotColor(app.connection.status)"), "状态点必须读同一份状态")
        XCTAssertTrue(diag.contains("storage_detail_offline"), "详情页必须说「未连接」而不是一律「已连接」")
        XCTAssertFalse(diag.contains("app.pairingLost ? PPColor.act : PPColor.safe"),
                       "状态点不得退回只看配对有效性")
        XCTAssertFalse(diag.contains("if app.pairingLost { return L.s(\"storage_detail_lost\") }"),
                       "正文不得退回只剩二元配对判断")

        XCTAssertTrue(photos.contains("app.connection"), "照片页必须读唯一连接状态")
        XCTAssertTrue(photos.contains("TimelineLiveChrome(connection: conn)"), "提示由唯一状态驱动")
        XCTAssertTrue(photos.contains("conn.needsRepair"))
        XCTAssertTrue(photos.contains("conn.daysUnreachable"), "失联天数由同一个状态携带")
        XCTAssertFalse(photos.contains("app.pairingLost"), "照片页不得再各自读 pairingLost")
        XCTAssertFalse(photos.contains("model.live"), "照片页不得再各自读订阅状态")
    }

    func testFeedFallbackTickAppendsOnly() async {
        let s = Source([.page([2, 1], next: nil), .page([3, 2, 1], next: nil)])
        let feed = Feed()
        let m = await loaded(s)
        m.attach(feed)
        feed.emit(.fallbackTick)
        await waitUntil("兜底追加") { m.items.count == 3 }
    }
}
