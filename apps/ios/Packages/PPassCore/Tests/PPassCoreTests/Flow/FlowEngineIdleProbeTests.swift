// #1005：本地已经判得出「没有要传的」时，任何触发都不许去连桌面（不探测、不问 presence、不申请租约）。
// 唯一例外是兜底的 PERIODIC：按设计要问桌面「这些还在吗」，留作对照。（对位 Android `FlowEngineIdleProbeTest.kt`）
// 反证：让 FlowEngine.hasWork 恒返回 true → 第一条用例的探测次数不为 0，红。
import XCTest
@testable import PPassCore

final class FlowEngineIdleProbeTests: XCTestCase {
    private let repeats = 5

    /// 已经备份过一张、之后什么都没变：账本无待办、无发现、无失败项。
    private func idleRig(_ name: String = #function) async throws -> Rig {
        let rig = try Rig(name)
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger(.mediaChange)
        XCTAssertEqual(try rig.state(1), .confirmed)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
        rig.probe.calls.set(0)
        rig.presence.calls.set(0)
        rig.lease.acquires.set(0)
        return rig
    }

    func testNoTriggerReachesTheDesktopWhenNothingIsLeftToTransfer() async throws {
        let rig = try await idleRig()
        for reason in TriggerReason.allCases where reason != .periodic {
            for _ in 0..<repeats { await rig.trigger(reason) }
            XCTAssertEqual(rig.probe.calls.get(), 0, "\(reason) × \(repeats) 不许探测桌面")
            XCTAssertEqual(rig.presence.calls.get(), 0, "\(reason) × \(repeats) 不许问 presence")
            XCTAssertEqual(rig.lease.acquires.get(), 0, "\(reason) × \(repeats) 不许申请租约")
        }
    }

    func testThePeriodicFallbackStillAsksTheDesktopOncePerTrigger() async throws {
        let rig = try await idleRig()
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.probe.calls.get(), 1)
        XCTAssertEqual(rig.presence.calls.get(), 1)
    }
}
