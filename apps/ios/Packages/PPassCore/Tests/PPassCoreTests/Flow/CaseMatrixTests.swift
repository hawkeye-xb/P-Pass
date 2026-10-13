// #339：04-case-matrix 里还没有被引擎 / 端口测试直接覆盖的那些行，各一条（方法名以矩阵 ID 开头）。
// 全部 63 行（含已废弃）与仅 iOS 的 I 组怎么落到测试 / 变体登记，见 CaseMatrixCoverageTests 的注册表。
import Foundation
import XCTest
@testable import PPassCore

final class CaseMatrixTests: XCTestCase {

    /// O-04：已确认的照片被编辑（内容 H1 → H2）→ 按新版本新建一行传到已确认；H1 那一行仍是已确认。
    /// 反证：只按 media id 判重（不看版本）→ H2 不传，红；改写 H1 那一行 → 红。
    func testO04_anEditedConfirmedPhotoIsSentAgainOnANewRowAndTheOldRowStaysConfirmed() async throws {
        let rig = try Rig()
        var p = rig.photo(1, generation: 1, content: "H1")
        let old = try rig.order(p, .confirmed)
        try rig.advanceG(1)
        await rig.start()
        p.modified = 500
        p.content = "H2"
        p.generation = 2
        rig.media.put(p)
        await rig.trigger()
        let fresh = try XCTUnwrap(rig.current(1))
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertEqual(fresh.state, .confirmed)
        XCTAssertEqual(fresh.contentHash, "blake3:H2")
        XCTAssertEqual(try rig.store.get(old.id)?.state, .confirmed)
        XCTAssertEqual(try rig.store.get(old.id)?.contentHash, "blake3:H1")
    }

    /// O-05：待办里的一张，原图已从照片库删除 → 取件后记「源已删」，不传、不重试（之后的对账轮也不再碰）。
    func testO05_aTodoPhotoDeletedFromTheLibraryIsSettledAsSourceMissingAndNeverRetried() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let o = try rig.order(p, .pending)
        try rig.advanceG(1)
        rig.media.remove(1)
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.store.get(o.id)?.state, .skippedSourceMissing)
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertEqual(rig.importer.imported.get(), [])
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    /// O-06 / X-03：暂停后「取消剩余」→ 跳过名单 + 在途改用户跳过；之后的兜底对账轮既不补传也不重试它们；新拍的照常传。
    func testO06_cancelledPhotosAreNeverPickedUpByLaterReconcileRounds() async throws {
        let rig = try Rig()
        for n in 1...3 { rig.photo(n, generation: Int64(n)) }
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await rig.engine.pause()
        rig.delivery.release()
        let written = try await rig.engine.cancelRemaining(rig.engine.remainingSnapshot())
        XCTAssertEqual(written, 3)
        for reason in [TriggerReason.periodic, .appForeground, .processStart] { await rig.trigger(reason) }
        XCTAssertEqual(rig.delivery.deliveredIds, [1], "只有取消前在飞的那一次")
        rig.photo(4, generation: 4)
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 4])
    }

    /// O-14 / X-04：把相册移出范围——不写任何 order 状态，待办张数立即不再包含它的照片。
    func testO14_removingAnAlbumFromTheScopeWritesNoOrderStateAndDropsItsPhotosFromTheCount() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1, bucket: "B7")
        rig.photo(2, generation: 2, bucket: "B8")
        rig.media.scope = ["B7", "B8"]
        rig.fakeControl!.pausedFlag = true
        await rig.start()
        var pending = await rig.pending()
        XCTAssertEqual(pending, 2)
        rig.media.scope = ["B7"]
        await rig.trigger(.foregroundMediaChange)
        pending = await rig.pending()
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(try rig.store.currentOrders().collect(), [], "改范围不写任何 order")
    }

    /// D-02：循环在跑时连续到达 3 次触发 → 只有一个循环、只申请一次租约、只开一条推送会话。
    func testD02_triggersWhileRunningCoalesceIntoTheOneLoop() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        for reason in [TriggerReason.mediaChange, .networkChange, .foregroundMediaChange] {
            let started = await rig.engine.trigger(reason)
            XCTAssertFalse(started)
        }
        rig.delivery.release()
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.lease.acquires.get(), 1)
        XCTAssertEqual(rig.delivery.sessions.get(), 1)
    }

    /// D-03 / C-06：传 #1 期间新拍 #3 → 同一次循环里按 G 取到它；3 张一共只申请一次租约、一条会话，传完释放。
    func testD03_aPhotoTakenDuringTheLoopIsSentInTheSameLoopUnderOneLease() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.delivery.onStart.set { r in if r.details.snapshot.mediaId == mid(1) { rig.photo(3, generation: 3) } }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2, 3])
        XCTAssertEqual(rig.lease.acquires.get(), 1)
        XCTAssertEqual(rig.lease.releases.get(), 1)
        XCTAssertEqual(rig.delivery.sessions.get(), 1)
        XCTAssertFalse(rig.lease.held.get())
    }

    /// D-08：范围内 10 张（3 张已确认、2 张在跳过名单）、范围外 5 张 → 入口计数 = 5，只读元数据，不导入、不申请租约。
    func testD08_theEntryCountIsExactAndReadsNoFile() async throws {
        let rig = try Rig()
        var inScope: [FakePhoto] = []
        for n in 1...10 { inScope.append(rig.photo(n, generation: Int64(n))) }
        for n in 11...15 { rig.photo(n, generation: Int64(n), bucket: "B99") }
        for p in inScope.prefix(3) { try rig.order(p, .confirmed) }
        let skips = inScope[3...4].map { SkipTarget(mediaId: $0.mediaId, sourceVersion: $0.sourceVersion, bucketId: "B7") }
        _ = try rig.store.cancelRemaining(skips, audit: nil)
        try rig.store.markScanDirty()
        rig.conditions.set(Conditions(autoBackupEnabled: false))
        await rig.start()
        await rig.trigger(.mediaChange)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 5)
        XCTAssertEqual(rig.importer.imported.get(), [])
        XCTAssertEqual(rig.lease.acquires.get(), 0)
    }

    /// R-01 / R-02（引擎一半）：一张新照片只导入（= 读原图 / 拉 iCloud）一次。
    func testR01_aNewPhotoIsImportedExactlyOnce() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.importer.imported.get(), [mid(1)])
        XCTAssertEqual(rig.delivery.requests.get().count, 1)
    }

    /// C-15：暂停只在备份中可用——等待中不生效（空闲见 FlowEngineTests 的 pause 那一条）。
    func testC15_pauseIsIgnoredWhileWaiting() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.probe.result.set(.unreachable)
        await rig.start()
        await rig.trigger()
        let view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        let paused = await rig.engine.pause()
        XCTAssertFalse(paused)
        XCTAssertFalse(rig.fakeControl!.pausedFlag)
    }

    /// E-02：已确认之后把它的相册移出范围，完成事实不受影响（仍是已确认）。
    func testE02_aConfirmedPhotoStaysConfirmedAfterItsAlbumLeavesTheScope() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .confirmed)
        rig.media.scope = ["B99"]
        await rig.trigger(.periodic)
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertEqual(try rig.store.countCurrentByState(bucketIds: nil)[.confirmed], 1)
    }

    /// E-03：「取消剩余」不碰已确认的行，也不把它算进 N。
    func testE03_cancelRemainingNeverTouchesConfirmedPhotos() async throws {
        let rig = try Rig()
        let one = rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        try rig.order(one, .confirmed)
        try rig.advanceG(1)
        await rig.start()
        rig.fakeControl!.pausedFlag = true
        let snapshot = try await rig.engine.remainingSnapshot()
        XCTAssertEqual(snapshot.count, 1)
        _ = try await rig.engine.cancelRemaining(snapshot)
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertFalse(try rig.store.isSkipped(mid(1)))
    }

    /// X-07：传了一半后暂停，原图在系统相册里被删 → 继续时记「源已删」（不计失败），取下一张。
    func testX07_aPausedPhotoDeletedBeforeContinueIsSettledAsSourceMissing() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await rig.engine.pause()
        rig.delivery.release()
        rig.media.remove(1)
        await rig.engine.resume()
        await rig.engine.awaitIdle()
        XCTAssertEqual(try rig.state(1), .skippedSourceMissing)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        XCTAssertEqual(try rig.state(2), .confirmed)
    }

    /// P-01：换到另一台桌面——旧的传输进度不带入（order 清空、新 id 抬到时间戳之上），用户意图（跳过名单）保留。
    func testP01_changingDesktopsDropsOldProgressButKeepsIntent() async throws {
        let rig = try Rig()
        let one = rig.photo(1, generation: 1)
        let two = rig.photo(2, generation: 2)
        try rig.store.claimOwner("desk-a", idFloor: 0)
        let oldRow = try rig.order(one, .transferring)
        _ = try rig.store.cancelRemaining([SkipTarget(mediaId: two.mediaId, sourceVersion: two.sourceVersion, bucketId: "B7")], audit: nil)
        XCTAssertTrue(try rig.store.claimOwner("desk-b", idFloor: 1_800_000_000_000))
        await rig.start()
        await rig.trigger()
        let fresh = try XCTUnwrap(rig.current(1))
        XCTAssertGreaterThan(fresh.id, 1_800_000_000_000)
        XCTAssertNotEqual(fresh.id, oldRow.id)
        XCTAssertEqual(fresh.state, .confirmed)
        XCTAssertTrue(try rig.store.isSkipped(mid(2)), "跳过名单是用户意图，跟哪台桌面无关")
        XCTAssertEqual(rig.delivery.deliveredIds, [1])
    }

    /// P-02：旧配对代号的回执无权改变新历史——不确认（当单张失败，计次、有上限）。
    func testP02_aReceiptFromTheOldPairingNeverConfirms() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.delivery.script.update { s in
            for _ in 0..<2 {
                s.append { r in .confirmed(CompletionReceipt(queueSequence: r.orderId, receiptId: "old", pairingEpoch: "e0", contentHash: r.contentHash, leaseToken: r.leaseToken)) }
            }
        }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .failed)
    }
}
