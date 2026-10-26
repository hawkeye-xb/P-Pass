// #891：Android `C413EngineTest` 逐条的 Swift 版（同名语义、同样的反证说明）。
// 真实的 FlowEngine + 真实的 SQLiteOrderStore + FakeMedia；导入、传输、租约、调度、桌面探测是计数的假端口。
import Foundation
import XCTest
@testable import PPassCore

final class FlowEngineTests: XCTestCase {

    // MARK: 取件优先级

    // 固定优先级：遗留续传 → 对账扫描（G 以下）→ 新照片（G 之后）→ 对账补传（待传输 / 失败重试）。
    // 反证：pickNext 把 discoveryStep 挪到 scanStep 之前 → 顺序变成 1, 3, 2, …，红。
    func testPickOrderIsLegacyThenScanThenNewThenReuploadsAndRetries() async throws {
        let rig = try Rig()
        let legacy = rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.photo(3, generation: 10)
        let reupload = rig.photo(4, generation: 3)
        let failed = rig.photo(5, generation: 4)
        try rig.advanceG(5)
        try rig.order(legacy, .transferring)
        try rig.order(reupload, .pending)
        let f = try rig.order(failed, .transferring)
        try rig.store.transition(f.id, expected: [.transferring], to: .failed, countAttempt: true)
        try rig.store.markScanDirty()
        await rig.start()

        await rig.trigger(.appForeground)

        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2, 3, 4, 5])
        for n in 1...5 { XCTAssertEqual(try rig.state(n), .confirmed, "#\(n)") }
        XCTAssertFalse(try rig.store.scanState().dirty, "scan finished")
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    // 失败重试只在对账轮；待传输（补传）任何一轮都取。反证：非对账轮也把 FAILED 放进来源 → MEDIA_CHANGE 这一轮就重传了，红。
    func testFailedRowsAreRetriedOnlyByAReconcileRound() async throws {
        let rig = try Rig()
        let failed = rig.photo(5, generation: 4)
        try rig.advanceG(5)
        let f = try rig.order(failed, .transferring)
        try rig.store.transition(f.id, expected: [.transferring], to: .failed, countAttempt: true)
        await rig.start()
        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertEqual(rig.lease.acquires.get(), 0, "no work → no lease")
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.delivery.deliveredIds, [5])
        XCTAssertEqual(rig.delivery.requests.get().first?.orderId, f.id)
    }

    // MARK: G 只由新照片推进

    // O-12：已有 order（遗留续传）提交不推进 G——否则 G 被它推高，跳过中间还没取到的新照片。
    // 反证：已有 order 的 Progress 带上 lookup 的位置 → #2 开始时 G 已经跳到 10，红。
    func testCommittingAnExistingOrderNeverMovesGPastANewPhoto() async throws {
        let rig = try Rig()
        let legacy = rig.photo(1, generation: 10)
        rig.photo(2, generation: 5)
        try rig.order(legacy, .transferring)
        let gAtSecond = Locked<[Int64]>([])
        rig.delivery.onStart.set { r in
            if r.details.snapshot.mediaId == mid(2) { gAtSecond.update { $0.append(try! rig.generation()) } }
        }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        XCTAssertEqual(gAtSecond.get(), [0], "the legacy commit left G alone")
        XCTAssertEqual(try rig.state(2), .confirmed)
    }

    // 扫描来源提交只推进 S，不推进 G；新照片提交推进 G。反证：progressOf(scan) 也带位置 → #3 开始时 G ≠ 30，红。
    func testAReconcileScanCommitMovesSAndLeavesGToNewPhotos() async throws {
        let rig = try Rig()
        try rig.advanceG(30)
        rig.photo(1, generation: 20)
        rig.photo(3, generation: 31)
        try rig.store.markScanDirty()
        let gAtNew = Locked<[Int64]>([])
        rig.delivery.onStart.set { r in
            if r.details.snapshot.mediaId == mid(3) { gAtNew.update { $0.append(try! rig.generation()) } }
        }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 3])
        XCTAssertEqual(gAtNew.get(), [30])
        XCTAssertEqual(try rig.generation(), 31)
    }

    // 同一批变化里的多张照片 generation 相同：G 带上 id，不会把同一批里还没轮到的一起跳过。
    func testPhotosSharingOneGenerationAreAllPicked() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 7)
        rig.photo(2, generation: 7)
        rig.delivery.script.update { $0.append { _ in .pathFailure("fetch_failed") } }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .transferring)
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 1, 2])
        XCTAssertEqual(try rig.state(2), .confirmed)
    }

    // MARK: 计数

    // 待办 = 范围内照片 − 跳过名单 − 已有结局。中断的新照片两个来源都看得到，只算一次；脏 / 不脏两条路径与弹窗的 N 相等。
    // 反证：不脏路径不按 media_id 去重 → 4 ≠ 3，红。
    func testTheTodoCountIsExactAndEachPhotoCountedOnce() async throws {
        let rig = try Rig()
        try rig.advanceG(5)
        let interrupted = rig.photo(10, generation: 10)
        rig.photo(11, generation: 11)
        let confirmed = rig.photo(2, generation: 2)
        let skipped = rig.photo(3, generation: 3)
        rig.photo(4, generation: 12, bucket: "B99")
        let failed = rig.photo(1, generation: 1)
        try rig.order(interrupted, .transferring)
        try rig.order(confirmed, .confirmed)
        _ = try rig.store.cancelRemaining([SkipTarget(mediaId: skipped.mediaId, sourceVersion: skipped.sourceVersion, bucketId: "B7")], audit: nil)
        let f = try rig.order(failed, .transferring)
        try rig.store.transition(f.id, expected: [.transferring], to: .failed, countAttempt: true)
        rig.fakeControl!.pausedFlag = true
        await rig.start()

        await rig.trigger(.mediaChange)
        var pending = await rig.pending()
        XCTAssertEqual(pending, 3, "not dirty")
        try rig.store.markScanDirty()
        await rig.trigger(.mediaChange)
        pending = await rig.pending()
        XCTAssertEqual(pending, 3, "dirty (full diff)")
        let snapshotCount = try await rig.engine.remainingSnapshot().count
        XCTAssertEqual(snapshotCount, 3)
        let known = await rig.engine.pendingKnown
        XCTAssertTrue(known)
    }

    // 一轮跑完待办归零，且随提交递减；本轮已完成计数。
    func testAfterACleanRoundNothingIsLeftAndTheRoundCountedItsPhotos() async throws {
        let rig = try Rig()
        for n in 1...3 { rig.photo(n, generation: Int64(n)) }
        let seen = Locked<[Int]>([])
        let engine = rig.engine!
        rig.delivery.progress.set { _, _ in seen.update { _ in }; let p = await engine.view.pending; seen.update { $0.append(p) } }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(seen.get(), [3, 2, 1])
        let view = await rig.engine.view
        XCTAssertEqual(view.pending, 0)
        XCTAssertEqual(view.doneThisRound, 3)
        XCTAssertEqual(view.state, .idle)
    }

    // MARK: 状态机

    // pause 只在 RUNNING；暂停后在飞的那张保持「传输中」、不计次数、释放租约；resume 只在 PAUSED，续传同一行。
    // 反证：pause 不看状态 → IDLE 时也写暂停标志，第一条断言红；收尾时把在飞的改成别的状态 → 第二组红。
    func testPauseOnlyWhileRunningKeepsTheInFlightOrderAndResumeContinuesIt() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        let pausedIdle = await rig.engine.pause()
        XCTAssertFalse(pausedIdle)
        XCTAssertFalse(rig.fakeControl!.pausedFlag)
        let resumedIdle = await rig.engine.resume()
        XCTAssertFalse(resumedIdle, "resume in IDLE")

        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        let running = await rig.engine.view.state
        XCTAssertEqual(running, .running)
        let first = try XCTUnwrap(rig.current(1))
        let paused = await rig.engine.pause()
        XCTAssertTrue(paused)
        rig.delivery.release()
        await rig.engine.awaitIdle()

        let state = await rig.engine.view.state
        XCTAssertEqual(state, .paused)
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        XCTAssertEqual(rig.delivery.cancelled.get(), [first.id])
        XCTAssertEqual(rig.lease.releases.get(), 1)
        XCTAssertEqual(rig.delivery.deliveredIds, [1])

        let resumed = await rig.engine.resume()
        XCTAssertTrue(resumed)
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 1, 2])
        XCTAssertEqual(rig.delivery.requests.get()[1].orderId, first.id, "resumed on the same tuple")
        XCTAssertEqual(try rig.state(1), .confirmed)
        let end = await rig.engine.view.state
        XCTAssertEqual(end, .idle)
    }

    // 断开（UX-06）：正在传的这一轮被取消、回到空闲，且不写暂停标志（暂停意图属于断开清单里的 keep）。
    // 反证：stopForDisconnect 不取消当前循环 → 状态仍是 running，红；误写暂停标志 → pausedFlag 为真，红。
    func testStopForDisconnectCancelsTheRunningRoundAndLeavesNoPauseFlag() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }

        await rig.engine.stopForDisconnect()

        let view = await rig.engine.view
        XCTAssertEqual(view.state, .idle)
        XCTAssertFalse(rig.fakeControl!.pausedFlag)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 1, "the in-flight order was cancelled")
    }

    // cancelRemaining 只在 PAUSED / WAITING；取消后清除暂停标志 → IDLE。反证：不清暂停标志 → 仍是 PAUSED，红。
    func testCancelWorksOnlyWhilePausedOrWaitingAndLeavesTheEngineIdle() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        let idle = try await rig.engine.cancelRemaining(rig.engine.remainingSnapshot())
        XCTAssertNil(idle, "IDLE")

        rig.probe.result.set(.unreachable)
        await rig.trigger()
        var view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(rig.fakeControl!.wait, .desktopUnreachable, "persisted")
        let waiting = try await rig.engine.cancelRemaining(rig.engine.remainingSnapshot())
        XCTAssertEqual(waiting, 1)
        view = await rig.engine.view
        XCTAssertEqual(view.state, .idle)
        XCTAssertNil(rig.fakeControl!.wait)

        rig.photo(2, generation: 2)
        rig.fakeControl!.pausedFlag = true
        let paused = try await rig.engine.cancelRemaining(rig.engine.remainingSnapshot())
        XCTAssertEqual(paused, 1)
        XCTAssertFalse(rig.fakeControl!.pausedFlag)
        view = await rig.engine.view
        XCTAssertEqual(view.state, .idle)
        XCTAssertEqual(try rig.store.countSkipped(bucketIds: nil), 2)
    }

    // 取消边界 = 弹窗那一刻：弹窗之后新拍的不被跳过；在飞的那张改用户跳过并丢弃半截。反证：确认时重算目标 → #3 也被跳过，红。
    func testCancelSkipsExactlyThePhotosShownInTheDialog() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        let inFlight = try XCTUnwrap(rig.current(1))
        await rig.engine.pause()
        rig.delivery.release()
        await rig.engine.awaitIdle()

        let snapshot = try await rig.engine.remainingSnapshot()
        XCTAssertEqual(snapshot.count, 2)
        rig.photo(3, generation: 3) // 弹窗之后新拍
        let written = try await rig.engine.cancelRemaining(snapshot)

        XCTAssertEqual(written, snapshot.count)
        XCTAssertEqual(try rig.state(1), .skippedByUser)
        XCTAssertTrue(try rig.store.isSkipped(mid(1)) && rig.store.isSkipped(mid(2)))
        XCTAssertFalse(try rig.store.isSkipped(mid(3)))
        XCTAssertEqual(rig.delivery.discarded.get(), [inFlight.id])
        let pending = await rig.pending()
        XCTAssertEqual(pending, 1)

        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 3], "only the photo taken after the dialog")
    }

    // MARK: 暂停期间只改意图

    // 暂停中：恢复已跳过、勾选新相册都只改意图，不探测、不申请租约、不读文件；继续之后由对账扫描取到。
    // 反证：restoreSkipped 只删名单不置脏 → 恢复的 #1 在 G 以下永远取不到，红；暂停中 SCOPE_ADDED 不置脏 → #5 取不到，红。
    func testWhilePausedOnlyIntentChangesAndResumingPicksUpRestoredPhotosAndANewAlbum() async throws {
        let rig = try Rig()
        let one = rig.photo(1, generation: 1)
        rig.photo(5, generation: 2, bucket: "B8") // 新相册里的老照片
        _ = try rig.store.cancelRemaining([SkipTarget(mediaId: one.mediaId, sourceVersion: one.sourceVersion, bucketId: "B7")], audit: nil)
        await rig.start()
        await rig.trigger() // 没有待办：G 走过 #1（在名单里）
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertGreaterThanOrEqual(try rig.generation(), 1)
        rig.fakeControl!.pausedFlag = true

        _ = try await rig.engine.restoreSkipped()
        rig.media.scope = ["B7", "B8"]
        await rig.trigger(.scopeAdded)

        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertEqual(rig.probe.calls.get(), 0)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        XCTAssertEqual(rig.importer.imported.get().count, 0)
        XCTAssertTrue(try rig.store.scanState().dirty)
        XCTAssertEqual(try rig.store.countSkipped(bucketIds: nil), 0)
        var pending = await rig.pending()
        XCTAssertEqual(pending, 2)

        await rig.engine.resume()
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 5])
        pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    // MARK: 旧版本 / 源已删

    // 中断期间照片被编辑（版本变了）：旧行「传输中」→ 源已删 + cancel_tuple，不计失败；新版本另起一行。
    func testAnOldVersionLeftTransferringIsDroppedAndTheNewVersionGetsANewRow() async throws {
        let rig = try Rig()
        var v1 = rig.photo(1, generation: 1, content: "old")
        let old = try rig.order(v1, .transferring)
        v1.modified = 999
        v1.content = "new"
        v1.generation = 2
        rig.media.put(v1)
        await rig.start()

        await rig.trigger()

        XCTAssertEqual(try rig.store.get(old.id)?.state, .skippedSourceMissing)
        XCTAssertEqual(try rig.store.get(old.id)?.attempts, 0)
        XCTAssertEqual(rig.delivery.discarded.get(), [old.id])
        let fresh = try XCTUnwrap(rig.current(1))
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertEqual(fresh.state, .confirmed)
        XCTAssertEqual(rig.delivery.requests.get().map(\.orderId), [fresh.id])
    }

    // 版本没跟上但内容变了（导入出来的 hash 与行里记的不符）：旧行源已删 + cancel_tuple；现在的字节另起一行传。
    // 反证一：去掉 hash 比对 → 旧 tuple 带着新内容续传，红。反证二：只结旧行不另起 → 这张漏传，requests 为空，红。
    func testALegacyOrderWhoseImportedHashNoLongerMatchesIsReplacedByANewRow() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let old = try rig.order(p, .transferring)
        try rig.advanceG(1)
        rig.importer.hashOverride.set([mid(1): "blake3:edited"])
        await rig.start()

        await rig.trigger()

        XCTAssertEqual(try rig.store.get(old.id)?.state, .skippedSourceMissing)
        XCTAssertEqual(rig.delivery.discarded.get(), [old.id])
        let fresh = try XCTUnwrap(rig.current(1))
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertEqual(fresh.state, .confirmed)
        XCTAssertEqual(fresh.contentHash, "blake3:edited")
        XCTAssertEqual(fresh.sourceVersion, p.sourceVersion)
        XCTAssertEqual(rig.delivery.requests.get().map(\.orderId), [fresh.id])
    }

    // 在途的这张所在相册被移出范围：不续传、丢弃半截、从待办消失；之后的触发不为它空转租约；相册加回来同一行续传。
    func testAnInFlightOrderWhoseAlbumLeftTheScopeIsNotResumed() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let o = try rig.order(p, .transferring)
        try rig.advanceG(1)
        rig.media.scope = ["B99"]
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertEqual(rig.delivery.discarded.get(), [o.id])
        XCTAssertEqual(try rig.state(1), .pending)
        var pending = await rig.pending()
        XCTAssertEqual(pending, 0)
        let acquires = rig.lease.acquires.get()
        let probes = rig.probe.calls.get()
        await rig.trigger(.mediaChange)
        await rig.trigger(.networkChange)
        XCTAssertEqual(rig.lease.acquires.get(), acquires)
        XCTAssertEqual(rig.probe.calls.get(), probes)
        rig.media.scope = ["B7"]
        await rig.trigger(.scopeAdded)
        XCTAssertEqual(rig.delivery.requests.get().map(\.orderId), [o.id])
        XCTAssertEqual(try rig.state(1), .confirmed)
        pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    // MARK: 错误分类在引擎里的落点

    // 对端失败：退出循环、不计次数、「传输中」保持、等待原因按种类；路径失败同上；源已删不计失败。
    // 反证：PeerFailure 走 fail() → FAILED / attempts=1，红；SourceMissing 当 ItemFailure → FAILED，红。
    func testPeerPathAndSourceMissingOutcomesNeverCountAFailure() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.script.update { $0.append { _ in .peerFailure(.storageFull, code: "storage_full") } }
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        var view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .desktopStorageFull)
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1, "#652：对端失败同样登记探测梯")

        rig.delivery.script.update { $0.append { _ in .pathFailure("fetch_failed") } }
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .transferring)
        view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .desktopUnreachable)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1, "#762：同一次故障（中间没成功过）不再加排探测")

        rig.delivery.script.update { $0.append { _ in .sourceMissing } }
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .skippedSourceMissing)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    // 桌面不健康（探测带回 library_writable=false）→ 不申请租约，等待中（具体原因）。
    func testAnUnhealthyDesktopKeepsTheLoopWaitingWithoutTheLease() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        let health = DesktopHealth(freeBytes: 100 * 1024 * 1024 * 1024, libraryWritable: false)
        rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: health, capabilities: []))
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .desktopLibraryUnavailable)
        XCTAssertEqual(view.desktopHealth, health)
    }

    // MARK: 失败重试上限

    // 单张失败当场重试 1 次 → FAILED（1 次）；兜底对账再试 1 次 → FAILED（2 次）；之后保持失败。
    // 反证：pickNext 不看 attempts 上限 → 第三轮对账又传，requests = 6，红。
    func testAFailingPhotoIsRetriedOnceOnTheSpotAndOnceByReconciliation() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.delivery.script.update { s in for _ in 0..<8 { s.append { _ in .itemFailure("boom") } } }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.requests.get().count, 2)
        XCTAssertEqual(try rig.current(1)?.attempts, 1)
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.delivery.requests.get().count, 4)
        XCTAssertEqual(try rig.current(1)?.attempts, OrderStoreLimits.maxFailures)
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.delivery.requests.get().count, 4)
        XCTAssertEqual(try rig.state(1), .failed)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 1, "still todo")
        XCTAssertEqual(Set(rig.delivery.requests.get().map(\.orderId)).count, 1, "the same row every time")
    }

    // MARK: 对账补传

    // 桌面缺失的已确认照片：新建一行（不复用原 order id），在租约之后问。反证：补传沿用原行 id → requests 里是旧 id，红。
    func testAConfirmedPhotoMissingOnTheDesktopIsReuploadedOnANewRow() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let old = try rig.order(p, .confirmed)
        try rig.advanceG(1)
        rig.presence.missingOnDesktop.set([p.hash])
        await rig.start()
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.presence.calls.get(), 1)
        let row = try XCTUnwrap(rig.current(1))
        XCTAssertNotEqual(old.id, row.id)
        XCTAssertEqual(rig.delivery.requests.get().map(\.orderId), [row.id])
        XCTAssertEqual(row.state, .confirmed)
    }

    // MARK: 租约之前不读文件 / 不走 presence

    // 入口只读元数据：租约被拒、桌面不可达时，一张都不导入（**也就不会触发任何 iCloud 下载**），也不问桌面「还在吗」。
    // 反证：把导入挪回入口 → imported 非空，红。
    func testNothingIsReadOrAskedOfTheDesktopBeforeTheLeaseIsHeld() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        try rig.order(p, .confirmed)
        rig.presence.missingOnDesktop.set([p.hash])
        rig.lease.grant.set(false)
        await rig.start()
        await rig.trigger(.appForeground)
        rig.probe.result.set(.unreachable)
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.importer.imported.get().count, 0)
        XCTAssertEqual(rig.presence.calls.get(), 0)
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
    }

    // 租约被拒 → 等待中；下一次触发照常再申请；拿到就清受阻原因。反证：把受阻原因当闸门 → 第二次触发不申请，红。
    func testARefusedLeaseWaitsAndTheNextTriggerSimplyTriesAgain() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.lease.grant.set(false)
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.lease.acquires.get(), 1)
        XCTAssertEqual(rig.fakeControl!.wait, .executionBlocked)
        XCTAssertEqual(rig.fakeControl!.block, .refused)
        rig.lease.grant.set(true)
        await rig.trigger()
        XCTAssertEqual(rig.lease.acquires.get(), 2)
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertNil(rig.fakeControl!.block)
    }

    // C-13：没有任何网络 → 在飞的这张立即判路径失败：停循环、保持传输中、等待中、挂探测。
    func testLosingTheNetworkStopsTheInFlightItemAsAPathFailure() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await rig.engine.onNetworkLost()
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(rig.fakeControl!.wait, .desktopUnreachable)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1)
        XCTAssertEqual(rig.lease.releases.get(), 1)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
    }

    // G 缺失（新装）：G 从当前位置起步、扫描置脏，已有照片由扫描按 id 取完。
    func testAFreshInstallScansTheExistingLibraryByIdAndStartsGAtTheNewest() async throws {
        let rig = try Rig(cursors: false)
        rig.photo(2, generation: 9)
        rig.photo(1, generation: 3)
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        XCTAssertEqual(try rig.generation(), 9)
        XCTAssertFalse(try rig.store.scanState().dirty)
    }

    // 导入时原图读不到（照片库还列着）：记源已删，不再算待办，G 照常推进、不计失败。
    func testAListedPhotoWhoseFileCannotBeReadIsSettledAsSourceMissing() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.importer.unreadable.set([mid(1)])
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .skippedSourceMissing)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(try rig.generation(), 1)
    }

    // 导入抛错：当场重试 1 次；仍失败记一次失败（有上限），G 推进，不在这张上打转。
    func testAnImportThatThrowsTwiceCountsOneFailureAndMovesOn() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.importer.failures.set([FakeImportError(), FakeImportError()])
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .failed)
        XCTAssertEqual(try rig.current(1)?.attempts, 1)
        XCTAssertEqual(rig.importer.imported.get(), [mid(1), mid(1), mid(2)])
        XCTAssertEqual(try rig.state(2), .confirmed)
    }

    // 设计 §2：先计数、再查条件。等待中时首页的「待备份」是真实张数，不是 0；等待原因落进持久化。
    func testTheCountComesBeforeTheConditions() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.conditions.set(Conditions(autoBackupEnabled: false))
        await rig.start()
        await rig.trigger(.mediaChange)
        let view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .disabled)
        XCTAssertEqual(rig.fakeControl!.wait, .disabled)
        XCTAssertEqual(view.pending, 2)
    }

    // 检查阶段（还没申请到租约）报 RUNNING，不报 IDLE。
    func testTheCheckingPhaseIsReportedAsRunning() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.probe.hold.set(true)
        await rig.start()
        await rig.engine.trigger(.mediaChange)
        await eventually("probe started") { rig.probe.calls.get() == 1 }
        let seen = await rig.engine.view.state
        rig.probe.releaseHold()
        await rig.engine.awaitIdle()
        XCTAssertEqual(seen, .running)
        XCTAssertEqual(try rig.state(1), .confirmed)
    }

    // 恢复已跳过之后：媒体源给出重复的行也不崩、照常传完。反证：todoTargets 去掉重复行保护 → 计数多算 1，红。
    func testRestoreKeepsWorkingWhenTheMediaSourceRepeatsARow() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        _ = try await rig.cancelRemainingNow()
        rig.media.duplicateInScope = [mid(2)]
        _ = try await rig.engine.restoreSkipped()
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
        let count = try await rig.engine.remainingSnapshot().count
        XCTAssertEqual(count, 0)
    }

    // #775：导入成功后建 order 失败：这次导入同样要放掉；这一轮按意外错误等待重试。
    // 反证：releasingOnAbort 只接取消（不接失败），或把 insert 移出作用域 → released 为空，红。
    func testAnImportIsReleasedWhenRecordingItsOrderFails() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        await rig.start()
        rig.store.failNextInsert = SQLiteError(code: 13, message: "database or disk is full")
        await rig.trigger()
        XCTAssertEqual(rig.importer.released.get(), [p.hash])
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .unexpectedError, "这一轮走不完，按意外错误等待重试")
    }

    // 导入了、还没传完这一轮就被取消（暂停）：放掉这次导入。反证：去掉 releasingOnAbort → released 为空，红。
    func testAnImportIsReleasedWhenTheRoundIsCancelledBeforeItIsDelivered() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await rig.engine.pause()
        XCTAssertEqual(rig.importer.released.get(), [p.hash])
    }

    // 后台备份关着、App 在前台时存入新照片：前台的媒体变化（人在场）照常备份；后台的 MEDIA_CHANGE 仍被开关挡住。
    func testAMediaChangeWhileTheAppIsVisibleBacksUpEvenWithBackgroundBackupOff() async throws {
        let rig = try Rig()
        rig.conditions.set(Conditions(autoBackupEnabled: false))
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        var view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .disabled)
        await rig.trigger(.foregroundMediaChange)
        XCTAssertEqual(rig.delivery.deliveredIds, [1])
        view = await rig.engine.view
        XCTAssertEqual(view.pending, 0)
    }

    // 媒体变化即重算待办：等待中新拍一张，待备份立即 +1；在跑时合并进来的也当场重算。反证：合并时不重算 → 第二段仍是 1，红。
    func testAMediaChangeRecountsTheBacklogWithoutWaitingForARound() async throws {
        let rig = try Rig()
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger(.foregroundMediaChange)
        var pending = await rig.pending()
        XCTAssertEqual(pending, 1)
        rig.conditions.set(Conditions())
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.foregroundMediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        rig.photo(2, generation: 2)
        await rig.engine.trigger(.foregroundMediaChange)
        pending = await rig.pending()
        XCTAssertEqual(pending, 2, "the in-flight one and the new one")
        rig.delivery.release()
        await rig.engine.awaitIdle()
        pending = await rig.pending()
        XCTAssertEqual(pending, 0)
    }

    // 配对后（扫描脏、全部已确认）：入口的全量差集为 0 → 扫描当场收掉、不申请租约；只为问桌面「还在吗」只在兜底轮申请。
    // 反证：去掉入口的 finishScan → hasWork 因扫描脏返回 true，acquires = 1，红。
    func testNothingToDoAfterRepairingDoesNotStartTheLease() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        try rig.order(p, .confirmed)
        try rig.advanceG(1)
        try rig.store.markScanDirty()
        await rig.start()
        await rig.trigger(.pairingRepaired)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        XCTAssertEqual(rig.probe.calls.get(), 0)
        XCTAssertFalse(try rig.store.scanState().dirty)
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.lease.acquires.get(), 1)
        XCTAssertEqual(rig.presence.calls.get(), 1)
    }
}
