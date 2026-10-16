import XCTest
@testable import PPass
@testable import PPassCore

final class NetworkStateTests: XCTestCase {
    final class FakeSource: NetworkPathSource, @unchecked Sendable {
        var handler: (@Sendable (Bool, Bool, [String]) -> Void)?
        func start(_ handler: @escaping @Sendable (Bool, Bool, [String]) -> Void) { self.handler = handler }
        func emit(satisfied: Bool, expensive: Bool, interfaces: [String] = ["en0"]) { handler?(satisfied, expensive, interfaces) }
    }

    /// 「仅 Wi‑Fi」的判据随路径更新走；每次更新都带着引擎动作交给 onUpdate，首次回调不带动作。
    func testPathUpdatesDriveExpensivenessAndTheEngineActions() {
        let source = FakeSource()
        let state = NetworkState(source: source)
        var updates: [NetworkPathTracker.Update] = []
        state.onUpdate = { updates.append($0) }

        source.emit(satisfied: true, expensive: false)
        XCTAssertFalse(state.isExpensive)
        source.emit(satisfied: true, expensive: false) // 重复回调（信号强度等）：去重，不触发
        source.emit(satisfied: true, expensive: true) // Wi‑Fi → 热点 / 蜂窝
        XCTAssertTrue(state.isExpensive)
        source.emit(satisfied: false, expensive: false) // 断网
        source.emit(satisfied: true, expensive: false) // 回来

        XCTAssertEqual(updates.map(\.action), [nil, nil, .changed, .lost, .changed])
        XCTAssertEqual(updates.map(\.recovered), [false, false, false, false, true])
    }
}
