import Foundation
import XCTest
@testable import PPassCore

/// #1069 / #1073：版本不兼容与「桌面拒了请求但不是照片的问题」在引擎里的落点。
/// 反证：把 FlowEngine 的 `.versionMismatch` 分支改成走 `fail()`，或探测的 `.versionMismatch` 改成 `.unreachable`，本组红。
final class VersionMismatchEngineTests: XCTestCase {
    /// 握手（hello 探测）发现不兼容：不申请租约、不发起传输、不计任何失败；等待原因指明更新哪一端。
    func testHandshakeMismatchStopsBeforeTheLeaseAndCountsNothing() async throws {
        for (side, wait) in [(OutdatedSide.phone, WaitReason.phoneOutdated), (.desktop, .desktopOutdated)] {
            let rig = try Rig()
            rig.photo(1, generation: 1)
            await rig.start()
            rig.probe.result.set(.versionMismatch(side))
            await rig.trigger()
            let view = await rig.engine.view
            XCTAssertEqual(view.state, .waiting, "\(side)")
            XCTAssertEqual(view.waitReason, wait, "\(side)")
            XCTAssertEqual(rig.lease.acquires.get(), 0, "不申请租约")
            XCTAssertEqual(rig.importer.imported.get(), [], "不发起传输")
            XCTAssertNil(try rig.current(1), "不建 order、不计次数")
        }
    }

    /// 心跳只在版本兼容时报可达：「需要更新」等待中收到可达 → 叫醒引擎，重新握手后照常备份（与 Android 同）。
    func testAReachableHeartbeatWakesTheLoopOutOfAVersionWait() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.probe.result.set(.versionMismatch(.desktop))
        await rig.trigger()
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        rig.probe.result.set(.reachable(advertisedEpoch: "e1", health: nil, capabilities: []))
        await rig.engine.onDesktopReachable()
        await eventually("lease requested after the wake") { rig.lease.acquires.get() == 1 }
    }

    /// 传输中途才收到版本拒绝（兜底）：不计次数，order 保持传输中可续传。
    func testMidTransferMismatchCountsNothingAndStaysResumable() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.script.update { $0.append { _ in .versionMismatch(.desktop) } }
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .desktopOutdated)
    }

    /// 桌面拒了请求但不是照片的问题（手机发错请求 / 不认识的 reason）：不计次数，退出本轮、退避（#762 的探测梯）。
    func testARejectedRequestIsNotThePhotosFault() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.script.update { $0.append { _ in .desktopRejected("bad_request") } }
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .unexpectedError)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1, "退避")
    }

    /// 电脑上的 P-Pass 出错了（internal）：对端失败，等待原因单独一种。
    func testDesktopInternalIsAPeerFailure() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.script.update { $0.append { _ in .peerFailure(.desktopInternal, code: "internal") } }
        await rig.trigger()
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .desktopInternal)
    }
}
