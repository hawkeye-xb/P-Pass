import XCTest
@testable import PPassCore

final class NetworkPathTrackerTests: XCTestCase {
    private func u(_ action: NetworkPathAction?, recovered: Bool = false) -> NetworkPathTracker.Update {
        .init(action: action, recovered: recovered)
    }

    /// 首次回调不触发引擎（启动由 LiveBackend.start 管），也不算恢复。
    func testTheFirstCallbackNeverTriggersTheEngine() {
        var a = NetworkPathTracker()
        XCTAssertEqual(a.update(satisfied: true, signature: "wifi"), u(nil))
        var b = NetworkPathTracker()
        XCTAssertEqual(b.update(satisfied: false, signature: "none"), u(nil))
    }

    /// 签名变了才通知引擎（对位 Android `changed()`）：换接口 / 昂贵度 → changed；整条路径没了 → lost；回来 → recovered。
    func testASignatureChangeMapsToChangedOrLost() {
        var t = NetworkPathTracker()
        _ = t.update(satisfied: true, signature: "en0|cheap")
        XCTAssertEqual(t.update(satisfied: true, signature: "en0|expensive"), u(.changed), "Wi‑Fi → 热点（昂贵度变）")
        XCTAssertEqual(t.update(satisfied: true, signature: "pdp_ip0|expensive"), u(.changed), "换接口")
        XCTAssertEqual(t.update(satisfied: false, signature: "none"), u(.lost))
        XCTAssertEqual(t.update(satisfied: true, signature: "en0|cheap"), u(.changed, recovered: true))
    }

    /// 签名没变的重复回调（信号强度等成串到达）不再触发——对位 Android `if (signature == lastNetworkSignature) return`。
    /// 反证：去掉去重 → 第二、三条各多触发一次，红。
    func testRepeatedCallbacksWithTheSameSignatureAreDropped() {
        var t = NetworkPathTracker()
        _ = t.update(satisfied: true, signature: "en0|cheap")
        XCTAssertEqual(t.update(satisfied: true, signature: "en0|cheap"), u(nil))
        XCTAssertEqual(t.update(satisfied: true, signature: "en0|cheap"), u(nil))
        XCTAssertEqual(t.update(satisfied: false, signature: "none"), u(.lost))
        XCTAssertEqual(t.update(satisfied: false, signature: "none"), u(nil), "重复的断网不再重复判路径失败")
    }

    /// 首次就是断网：之后回来也算 recovered。
    func testStartingOfflineThenComingBackIsRecovered() {
        var t = NetworkPathTracker()
        _ = t.update(satisfied: false, signature: "none")
        XCTAssertEqual(t.update(satisfied: true, signature: "en0|cheap"), u(.changed, recovered: true))
    }

    /// 分发顺序：provider.networkChange 先于引擎；无动作什么都不做。
    func testDispatchProbesTheProviderBeforeTheEngine() async {
        final class Calls: @unchecked Sendable { var list: [String] = [] }
        let calls = Calls()
        var t = NetworkPathTracker()
        let seq: [(Bool, String)] = [(true, "a"), (true, "a"), (true, "b"), (false, "none"), (true, "a")]
        for (ok, sig) in seq {
            await dispatchNetworkPath(t.update(satisfied: ok, signature: sig),
                                      providerNetworkChange: { calls.list.append("provider") },
                                      engineLost: { calls.list.append("lost") },
                                      engineChanged: { calls.list.append("changed") })
        }
        XCTAssertEqual(calls.list, ["provider", "changed", "provider", "lost", "provider", "changed"], "首次与重复都不分发")
    }
}
