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
        rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: nil, capabilities: []))
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

    /// 不该发生的错误（这里用 `grant_conflict`，`bad_request` / 未登记值等同一条路）：一张照片反复被拒，只算它自己的单张失败，
    /// 后面的照片照常传完；不进等待、不退出本轮。反证：把 `reasonClass` 里这类 reason 改回退出本轮（如对端失败），本条红。
    func testARepeatedlyRejectedPhotoDoesNotBlockTheOnesAfterIt() async throws {
        let rig = try Rig()
        for n in 1...3 { rig.photo(n, generation: Int64(n)) }
        let stuck = mid(1)
        rig.delivery.script.update { s in
            for _ in 0..<12 {
                s.append { r in
                    r.details.snapshot.mediaId == stuck
                        ? classifyDeliveryFailure(DesktopRejected(reason: .registered(.grantConflict), method: "flow.offer"))
                        : FakeDelivery.confirmed(r)
                }
            }
        }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .failed)
        XCTAssertEqual(try rig.current(1)?.attempts, 1, "当场重试一次后记一次失败")
        XCTAssertEqual(try rig.state(2), .confirmed)
        XCTAssertEqual(try rig.state(3), .confirmed)
        let view = await rig.engine.view
        XCTAssertNotEqual(view.state, .waiting, "不进等待")
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 0, "不排探测梯")
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
