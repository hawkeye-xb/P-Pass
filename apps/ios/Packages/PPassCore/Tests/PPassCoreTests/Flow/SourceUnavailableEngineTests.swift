// #1731：来源整体不可用（SourceUnavailable）的引擎缝——整条 Flow 等待，不推进 G/S、不写源缺失、
// 不计单张失败、在途 order 原样不动；恢复后下一轮照常。反证说明写在每条测试注释里：去掉对应的
// 捕获（引擎按单张失败 / unexpectedError 口径处理）测试就红。
import Foundation
import XCTest
@testable import PPassCore

final class SourceUnavailableEngineTests: XCTestCase {

    // 导入时抛 SourceUnavailable：进 WAITING/sourceUnavailable，G 不推进、不建行、不计失败、不排探测。
    // 反证：引擎没有这条缝时，importWithRetry 把它当普通导入错误吞掉（两次都抛 → 单张失败：建行、计次、推进游标），红。
    func testImportThrowingSourceUnavailableWaitsTheWholeFlowWithoutCountingAnything() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.importer.failures.set([SourceUnavailable(reason: "bookmark revoked")])
        await rig.start()

        await rig.trigger()

        let view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .sourceUnavailable)
        let gen1 = try rig.generation()
        XCTAssertEqual(gen1, 0, "G 不推进")
        let s1 = try rig.state(1)
        XCTAssertNil(s1, "不建行（没有失败次数可计）")
        XCTAssertEqual(rig.importer.imported.get().count, 1, "不按单张失败重试第二次")
        XCTAssertFalse(rig.fakeControl!.ladderSpent, "等用户重新授权，不排退避探测")
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 0)
    }

    // lookup 时抛 SourceUnavailable（fresh 取件）：同样整条 Flow 等待、什么都不写。
    // 反证：lookup 的异常没有专门分类时会沿 runCycle 抛到 drain 落成 WAITING/unexpectedError，红。
    func testLookupThrowingSourceUnavailableOnAFreshItemWaitsWithoutWritingAnything() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.media.lookupThrows.set(SourceUnavailable(reason: "root not accessible"))
        await rig.start()

        await rig.trigger()

        let view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .sourceUnavailable)
        let gen2 = try rig.generation()
        XCTAssertEqual(gen2, 0, "G 不推进")
        let s2 = try rig.state(1)
        XCTAssertNil(s2, "不建行")
        XCTAssertEqual(rig.importer.imported.get(), [], "没走到导入")
    }

    // lookup 时抛 SourceUnavailable（在途 order）：行原样不动（transferring 保持），不加次数。
    // 反证：按单张失败口径会 transition 成 failed 并 countAttempt，红。
    func testLookupThrowingSourceUnavailableOnAnInFlightOrderLeavesTheRowUntouched() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let order = try rig.order(p, .transferring)
        rig.media.lookupThrows.set(SourceUnavailable(reason: "bookmark revoked"))
        await rig.start()

        await rig.trigger()

        let view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .sourceUnavailable)
        let row = try rig.store.get(order.id)
        XCTAssertEqual(row?.state, .transferring, "在途 order 原样不动")
        XCTAssertEqual(row?.attempts, 0, "不计失败")
    }

    // 恢复：等待中下一轮（回前台触发）来源恢复 → 照常传完，WAITING 清除。
    // 反证：等待原因把引擎卡死（下一轮不再取件）的话这条红。
    func testTheNextRoundAfterRecoveryTransfersNormallyAndClearsTheWait() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.importer.failures.set([SourceUnavailable(reason: "bookmark revoked")])
        await rig.start()
        await rig.trigger()
        let waiting = await rig.engine.view
        XCTAssertEqual(waiting.waitReason, .sourceUnavailable)

        await rig.trigger(.appForeground)

        let view = await rig.engine.view
        let st = try rig.state(1)
        XCTAssertEqual(st, .confirmed)
        XCTAssertEqual(view.state, .idle)
        XCTAssertNil(view.waitReason)
    }

    // 等待中（sourceUnavailable）的对账轮不写 source_missing：即使相册权限是完整的、照片已从库里消失。
    // 反证：去掉 reconcileSourcePresence 的等待守卫 → photo 1 被标 skippedSourceMissing，红。
    func testPresenceReconciliationDoesNotWriteSourceMissingWhileWaitingForASource() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger(.periodic)
        let st = try rig.state(1)
        XCTAssertEqual(st, .confirmed)

        // 来源不可用等待中；同一轮里 photo 1 也从照片库消失。
        rig.importer.failures.set([SourceUnavailable(reason: "bookmark revoked")])
        rig.photo(2, generation: 2)
        rig.media.remove(1)
        await rig.trigger(.periodic)

        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .sourceUnavailable, "photo 2 的导入抛出来，整条 Flow 等待")
        let st1 = try rig.state(1)
        XCTAssertEqual(st1, .confirmed, "缺席不再可信，已确认的不动")

        // 恢复后：photo 1 真的没了，下一轮对账把它标上 source_missing（缺席重新可信；状态仍 confirmed，副本不动）。
        rig.importer.failures.set([])
        await rig.trigger(.periodic)
        let st2 = try rig.store.currentForMedia(mid(1))
        XCTAssertEqual(st2?.sourceMissing, true, "恢复后缺席可信，照常判定")
        XCTAssertEqual(st2?.state, .confirmed, "presence 对账只标标志，不改状态")
    }

    // 扫描 / 发现阶段抛 SourceUnavailable（目录枚举中途失败）：整条 Flow 等待、扫描保持脏，不计失败。
    // 反证：runCycle 不把 SourceUnavailable 分类成等待 → 沿 drain 落成 WAITING/unexpectedError，红。
    func testScanThrowingSourceUnavailableWaitsAndKeepsTheScanDirty() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        try rig.store.markScanDirty()
        rig.media.scanThrows.set(SourceUnavailable(reason: "enumeration failed mid-way"))
        await rig.start()

        await rig.trigger(.periodic)

        let view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .sourceUnavailable)
        let dirty = try rig.store.scanState().dirty
        XCTAssertTrue(dirty, "本轮报错，扫描保持脏，下轮从头")
        let gen3 = try rig.generation()
        XCTAssertEqual(gen3, 0, "G 不推进")
    }

    // 每种等待原因的唤醒映射（C-08 的穷举侧）：sourceUnavailable 要用户重新授权 → awaitsUser、不排探测。
    // 反证：映射成 retryProbes 会在 FlowEngineIOSTests.testEveryWaitReasonRegistersTheRightWake 红。
    func testWakePlanForSourceUnavailableAwaitsTheUser() {
        XCTAssertEqual(wakePlanOf(.sourceUnavailable), .awaitsUser)
    }

    // rawValue 固定（持久化在 flow-control.json 里，改名会让旧值解不出来）。
    func testRawValueIsStableForPersistence() {
        XCTAssertEqual(WaitReason.sourceUnavailable.rawValue, "SOURCE_UNAVAILABLE")
    }
}
