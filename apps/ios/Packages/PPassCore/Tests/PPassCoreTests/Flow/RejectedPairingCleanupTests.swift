// #1119：被拒即清理的幂等性。
import Foundation
import XCTest
@testable import PPassCore

final class RejectedPairingCleanupTests: XCTestCase {
    private final class Rig: @unchecked Sendable {
        let local = Locked<String?>("e1")
        let announced = Locked<[String]>([])
        let cleared = Locked(0)
        let gate = Gate()
        let hold = Locked(false)
        lazy var cleanup = RejectedPairingCleanup(
            localPairingId: { [local] in local.get() },
            announce: { [announced] id in announced.update { $0.append(id) } },
            clear: { [self] in
                cleared.update { $0 += 1 }
                if hold.get() { try? await gate.wait() }
                local.set(nil) // 清理删掉配对记录
            },
            logger: NoopLogger())
    }

    /// 重复收到只清一次；清完之后再收到拒绝是空操作；通知先于清理。
    /// 反证：去掉「盘上没有配对 / 代号不符就返回」的判断，第二次会再清一次，cleared 变 2，红。
    func testTheSecondRejectionAfterTheCleanupIsANoOp() async {
        let r = Rig()
        let first = await r.cleanup.handle(rejectedPairingId: "e1")
        let second = await r.cleanup.handle(rejectedPairingId: "e1")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(r.cleared.get(), 1)
        XCTAssertEqual(r.announced.get(), ["e1"], "提示只发一次")
    }

    /// 多条路径同时发现：只有一条执行清理，其余在清理进行中就返回。
    /// 反证：去掉 inFlight 的 claim，并发的第二条也会进入清理，cleared 变 2，红。
    func testConcurrentDiscoveriesCleanOnce() async {
        let r = Rig()
        r.hold.set(true)
        let running = Task { await r.cleanup.handle(rejectedPairingId: "e1") }
        await eventually("清理已开始") { r.cleared.get() == 1 }
        let raced = await r.cleanup.handle(rejectedPairingId: "e1")
        XCTAssertFalse(raced, "清理进行中又来一条：空操作")
        r.gate.open()
        let ran = await running.value
        XCTAssertTrue(ran)
        XCTAssertEqual(r.cleared.get(), 1)
    }

    /// 重新扫码之后迟到的旧拒绝（旧代号）不许清掉新配对。
    /// 反证：不比较代号只看「有没有配对」，新配对被清，红。
    func testAStaleRejectionDoesNotTouchANewerPairing() async {
        let r = Rig()
        r.local.set("e2")
        let ran = await r.cleanup.handle(rejectedPairingId: "e1")
        XCTAssertFalse(ran)
        XCTAssertEqual(r.cleared.get(), 0)
        XCTAssertEqual(r.local.get(), "e2")
    }

    /// 清理没把配对删掉（失败）时，之后再收到拒绝要能重试——被动断开要可靠。
    func testAFailedCleanupIsRetriedOnTheNextRejection() async {
        let local = Locked<String?>("e1")
        let attempts = Locked(0)
        let cleanup = RejectedPairingCleanup(localPairingId: { local.get() }, announce: { _ in },
                                             clear: { attempts.update { $0 += 1 }; if attempts.get() == 2 { local.set(nil) } }, logger: NoopLogger())
        _ = await cleanup.handle(rejectedPairingId: "e1")
        let again = await cleanup.handle(rejectedPairingId: "e1")
        XCTAssertTrue(again)
        XCTAssertEqual(attempts.get(), 2)
    }
}
