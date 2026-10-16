import XCTest
@testable import PPassCore

final class NetworkPathTrackerTests: XCTestCase {
    /// 首次回调不触发引擎（启动由 LiveBackend.start 管），也不算恢复。
    func testTheFirstCallbackNeverTriggersTheEngine() {
        for satisfied in [true, false] {
            var t = NetworkPathTracker()
            XCTAssertEqual(t.update(satisfied: satisfied), .init(action: nil, recovered: false))
        }
    }

    /// 之后每次更新都要通知引擎：satisfied → changed（含 Wi‑Fi↔蜂窝换路），否则 lost；断网回来 recovered。
    func testEveryLaterUpdateMapsToChangedOrLost() {
        var t = NetworkPathTracker()
        _ = t.update(satisfied: true)
        XCTAssertEqual(t.update(satisfied: true), .init(action: .changed, recovered: false), "换接口 / 昂贵度变化")
        XCTAssertEqual(t.update(satisfied: false), .init(action: .lost, recovered: false))
        XCTAssertEqual(t.update(satisfied: false), .init(action: .lost, recovered: false))
        XCTAssertEqual(t.update(satisfied: true), .init(action: .changed, recovered: true))
    }

    /// 首次就是断网：之后回来也算 recovered（对位旧 onRecovered 的 `satisfied == false && now`）。
    func testStartingOfflineThenComingBackIsRecovered() {
        var t = NetworkPathTracker()
        _ = t.update(satisfied: false)
        XCTAssertEqual(t.update(satisfied: true), .init(action: .changed, recovered: true))
    }

    /// 分发顺序：provider.networkChange 先于引擎；首次回调什么都不做。
    func testDispatchProbesTheProviderBeforeTheEngine() async {
        final class Calls: @unchecked Sendable { var list: [String] = [] }
        let calls = Calls()
        var t = NetworkPathTracker()
        for satisfied in [true, true, false, true] {
            await dispatchNetworkPath(t.update(satisfied: satisfied),
                                      providerNetworkChange: { calls.list.append("provider") },
                                      engineLost: { calls.list.append("lost") },
                                      engineChanged: { calls.list.append("changed") })
        }
        XCTAssertEqual(calls.list, ["provider", "changed", "provider", "lost", "provider", "changed"], "首次回调不分发")
    }
}
