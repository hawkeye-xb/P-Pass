// #340（IOS-14）：前台追赶 + BGProcessingTask 尽力而为的调度逻辑（系统注册之外的部分全在这里测）。
import Foundation
import XCTest
@testable import PPassCore

final class RecordingSubmitter: BackgroundTaskSubmitter, @unchecked Sendable {
    let submitted = Locked<[BackgroundTaskRequestSpec]>([])
    let cancels = Locked(0)
    let refuse = Locked(false)
    struct Refused: Error {}

    func submit(_ spec: BackgroundTaskRequestSpec) throws {
        if refuse.get() { throw Refused() }
        submitted.update { $0.append(spec) }
    }

    func cancelAll() { cancels.update { $0 += 1 } }
    var last: BackgroundTaskRequestSpec? { submitted.get().last }
}

final class ForegroundCatchupTests: XCTestCase {

    /// 验收 1（E2 一半）：回到前台 → 一轮带对账的补捞 → 新照片被传。
    func testComingBackToTheForegroundCatchesUp() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        let catchup = ForegroundCatchup(engine: rig.engine)
        let issued = await catchup.appDidBecomeActive()
        XCTAssertTrue(issued)
        await catchup.awaitSettled()
        XCTAssertEqual(rig.delivery.deliveredIds, [1])
    }

    /// 验收 2：连续多次回前台只跑一轮（对位 Android 那条 KEEP 唯一任务）。
    /// 反证：每次 resume 都发触发 → 引擎在跑完之后又因合并进来的 APP_FOREGROUND 多跑一轮（lease 申请 2 次），红。
    func testRepeatedResumesCoalesceIntoOneRound() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        let catchup = ForegroundCatchup(engine: rig.engine)
        await catchup.appDidBecomeActive()
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        for _ in 0..<5 {
            let issued = await catchup.appDidBecomeActive()
            XCTAssertFalse(issued)
        }
        rig.delivery.release()
        await catchup.awaitSettled()
        let issuedCount = await catchup.issued
        XCTAssertEqual(issuedCount, 1)
        XCTAssertEqual(rig.lease.acquires.get(), 1)
        // 跑完之后的下一次回前台照常补捞。
        let again = await catchup.appDidBecomeActive()
        XCTAssertTrue(again)
        await catchup.awaitSettled()
    }

    /// 验收 5：暂停期间回前台不恢复消费（只重算待办）。
    func testAResumeWhilePausedDoesNotConsume() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.fakeControl?.pausedFlag = true
        await rig.start()
        let catchup = ForegroundCatchup(engine: rig.engine)
        await catchup.appDidBecomeActive()
        await catchup.awaitSettled()
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        XCTAssertEqual(rig.fakeControl?.pausedFlag, true, "回前台不解除暂停")
        let pending = await rig.pending()
        XCTAssertEqual(pending, 1)
    }

    /// 验收 4：Wi‑Fi 条件不满足时回前台 → 等待中（WIFI），不计失败、不申请租约。
    func testAResumeOnCellularWithWifiOnlyWaitsWithoutCounting() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        await rig.start()
        let catchup = ForegroundCatchup(engine: rig.engine)
        await catchup.appDidBecomeActive()
        await catchup.awaitSettled()
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .wifi)
        XCTAssertNil(try rig.current(1))
        XCTAssertEqual(rig.lease.acquires.get(), 0)
    }
}
