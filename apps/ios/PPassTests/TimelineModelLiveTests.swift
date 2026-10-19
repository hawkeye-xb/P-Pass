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

    func testFeedFallbackTickAppendsOnly() async {
        let s = Source([.page([2, 1], next: nil), .page([3, 2, 1], next: nil)])
        let feed = Feed()
        let m = await loaded(s)
        m.attach(feed)
        feed.emit(.fallbackTick)
        await waitUntil("兜底追加") { m.items.count == 3 }
    }
}
