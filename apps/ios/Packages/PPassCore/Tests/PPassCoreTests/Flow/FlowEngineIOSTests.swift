// #891：Android 其余引擎测试文件（C409 / C439 / C459 / AUDIT07 / ARCH13 控制）里与 iOS 相关的语义，
// 加上只有 iOS 才有的三件事：iCloud 原图（#311 D4）、发现游标失效（3105，F3）、执行租约被收回。
import Foundation
import XCTest
@testable import PPassCore

final class FlowEngineIOSTests: XCTestCase {

    // MARK: #1016：字节数以导入为准

    /// iOS 的 lookup 在取原图之前给不出字节数（0）：交付请求与首页的「当前这一张」都用导入时读到的实际字节数。
    /// 反证：引擎沿用 lookup 的 details → 请求里 sizeBytes=0，桌面拿不到大小、首页总字节为 0，红。
    func testDeliveryUsesTheImportedSizeWhenLookupCannotTell() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        rig.media.sizeUnknownBeforeImport.set(true)
        await rig.start()
        await rig.trigger()

        let requests = rig.delivery.requests.get()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.details.sizeBytes, p.size)
        XCTAssertGreaterThan(p.size, 0)
    }

    // MARK: #1092：取原图这一段单独显示

    /// 从 iCloud 下载原图期间：视图给出「正在取原图」这一项（来自 iCloud、带进度），上一张已传完的不再挂在 current 上
    /// ——首页的「没有新数据」计时只认 current 的字节，下载期间就不会误报。下载完开始交付后 fetching 收起。
    /// 反证：不设 fetching、不清 current → 视图仍是上一张（字节不动），红。
    func testWhileFetchingFromICloudTheViewShowsTheFetchNotThePreviousItem() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.importer.iCloudProgress.set([mid(2): [0.5]])
        rig.importer.holdIds.set([mid(2)])
        await rig.start()
        await rig.engine.trigger(.mediaChange)
        await eventually("fetching photo 2 from iCloud") { await rig.engine.view.fetching?.fraction == 0.5 }

        let v = await rig.engine.view
        XCTAssertEqual(rig.delivery.deliveredIds, [1], "第 1 张已传完")
        XCTAssertNil(v.current, "上一张不再挂在 current 上")
        XCTAssertEqual(v.fetching?.mediaId, mid(2))
        XCTAssertEqual(v.fetching?.fromICloud, true)
        XCTAssertEqual(v.state, .running)

        rig.importer.releaseHold()
        await eventually("photo 2 delivered") { rig.delivery.deliveredIds == [1, 2] }
        let after = await rig.engine.view
        XCTAssertNil(after.fetching)
    }

    /// 本机原图（导入端不回报 iCloud）：取原图这一段 fromICloud 保持 false，首页按普通「传输中」显示。
    func testLocalFetchIsNotReportedAsICloud() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.importer.holdIds.set([mid(1)])
        await rig.start()
        await rig.engine.trigger(.mediaChange)
        await eventually("fetching photo 1") { await rig.engine.view.fetching?.mediaId == mid(1) }
        let fromICloud = await rig.engine.view.fetching?.fromICloud
        XCTAssertEqual(fromICloud, false)
        rig.importer.releaseHold()
        await eventually("delivered") { rig.delivery.deliveredIds == [1] }
    }

    // MARK: #311 D4：iCloud 原图

    /// 新照片的原图在 iCloud、因网络拉不下来：不建行、不推进 G、不计失败；等待中（ORIGINAL_UNAVAILABLE）+ 探测梯。
    /// 网络回来后同一张照常传完。反证：把 originalUnavailable 当导入失败（抛错）→ 记 FAILED、attempts=1，红。
    func testANewPhotoWhoseICloudOriginalCannotBeFetchedWaitsWithoutCountingAFailure() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.importer.iCloudOffline.set([mid(1)])
        await rig.start()
        await rig.trigger()

        XCTAssertNil(try rig.current(1), "不建行")
        XCTAssertEqual(try rig.generation(), 0, "G 不越过它")
        XCTAssertEqual(rig.delivery.requests.get().count, 0, "队头那张拿不到原图，这一轮停下，不跳过它去传后面的")
        var view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .originalUnavailable)
        XCTAssertEqual(view.pending, 2)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1)
        XCTAssertEqual(rig.lease.releases.get(), 1, "退出循环、释放租约")

        rig.importer.iCloudOffline.set([])
        await rig.trigger(.networkChange)
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        view = await rig.engine.view
        XCTAssertEqual(view.state, .idle)
        XCTAssertEqual(rig.scheduler.probesCancelled.get(), 1, "#762：成功了，撤掉这组探测")
    }

    /// 遗留续传的那张原图被清出本地、又拉不下来：行原样不动（传输中、0 次），等待中。
    func testALegacyOrderWhoseICloudOriginalCannotBeFetchedIsLeftAsItIs() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let o = try rig.order(p, .transferring)
        try rig.advanceG(1)
        rig.importer.iCloudOffline.set([mid(1)])
        await rig.start()
        await rig.trigger()
        let row = try XCTUnwrap(rig.store.get(o.id))
        XCTAssertEqual(row.state, .transferring)
        XCTAssertEqual(row.attempts, 0)
        XCTAssertEqual(rig.delivery.discarded.get(), [], "不丢桌面半截")
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .originalUnavailable)
    }

    /// 资源确实不可得（不是网络问题，导入抛错）：才计入失败预算。
    func testAnOriginalThatIsGenuinelyUnavailableCountsAsAFailure() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.importer.failures.set([FakeImportError(), FakeImportError()])
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.state(1), .failed)
        XCTAssertEqual(try rig.current(1)?.attempts, 1)
    }

    /// D-08 + D4：入口计数只读元数据——条件不满足 / 桌面不可达 / 租约被拒时，一次导入（= 一次 iCloud 下载）都没有。
    func testTheEntryNeverTriggersAnICloudDownload() async throws {
        let rig = try Rig()
        for n in 1...3 { rig.photo(n, generation: Int64(n)) }
        await rig.start()
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        await rig.trigger(.foregroundMediaChange)
        rig.conditions.set(Conditions())
        rig.probe.result.set(.unreachable)
        await rig.trigger(.foregroundMediaChange)
        rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: nil, capabilities: []))
        rig.lease.grant.set(false)
        await rig.trigger(.foregroundMediaChange)
        XCTAssertEqual(rig.importer.imported.get(), [])
        let pending = await rig.pending()
        XCTAssertEqual(pending, 3)
    }

    /// 网络在 iCloud 下载途中断掉（onNetworkLost）：导入被取消，什么都不建、什么都不计。
    func testLosingTheNetworkDuringAnICloudDownloadCountsNothing() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.importer.hold.set(true)
        await rig.start()
        await rig.engine.trigger(.mediaChange)
        await eventually("import started") { rig.importer.imported.get().count == 1 }
        await rig.engine.onNetworkLost()
        XCTAssertNil(try rig.current(1))
        XCTAssertEqual(rig.fakeControl!.wait, .desktopUnreachable)
        rig.importer.releaseHold()
    }

    // MARK: #911：手机本地空间不足

    /// I-09：取原图时手机空间不足 → 不建行、不推进 G、不计失败；全局等待中（LOCAL_STORAGE_FULL）+ 探测梯；
    /// 后面的照片也不去试（换一张照样写不下）；空间释放后照常传完。
    /// 反证：把空间不足当单张失败 → 逐张记 FAILED、把整队的失败预算耗光，红。
    func testPhoneStorageFullWaitsWithoutCountingAnyFailure() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.importer.phoneStorageFull.set(true)
        await rig.start()
        await rig.trigger()
        XCTAssertNil(try rig.current(1))
        XCTAssertNil(try rig.current(2))
        XCTAssertEqual(rig.importer.imported.get(), [mid(1)], "队头写不下就停，不逐张去试")
        XCTAssertEqual(try rig.generation(), 0)
        var view = await rig.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .localStorageFull)
        XCTAssertEqual(view.pending, 2)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1)

        rig.importer.phoneStorageFull.set(false)
        await rig.trigger(.unreachableProbe)
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        view = await rig.engine.view
        XCTAssertEqual(view.state, .idle)
    }

    /// I-09（遗留续传）：在途的那张行原样不动（传输中、0 次）。
    func testPhoneStorageFullLeavesALegacyOrderAsItIs() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let o = try rig.order(p, .transferring)
        try rig.advanceG(1)
        rig.importer.phoneStorageFull.set(true)
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try rig.store.get(o.id)?.state, .transferring)
        XCTAssertEqual(try rig.store.get(o.id)?.attempts, 0)
        XCTAssertEqual(rig.fakeControl?.wait, .localStorageFull)
    }

    // MARK: F3：发现游标失效（3105）

    /// token 过期 → G 重置到当前位置、扫描置脏；已确认的同版本照片不重传（needsNewOrder 看当前行），只传真正的新照片。
    /// 反证：过期后不置脏、只重置 G → 过期期间新拍的 #3（在新 G 之下）永远取不到，红。
    func testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates() async throws {
        let rig = try Rig()
        let one = rig.photo(1, generation: 1)
        let two = rig.photo(2, generation: 2)
        try rig.order(one, .confirmed)
        try rig.order(two, .confirmed)
        try rig.advanceG(2)
        await rig.start()
        rig.photo(3, generation: 3) // 过期期间新拍的
        rig.media.expireTokens()

        await rig.trigger()

        XCTAssertEqual(rig.delivery.deliveredIds, [3], "只传真正没备份的那张")
        XCTAssertEqual(try rig.state(3), .confirmed)
        XCTAssertFalse(try rig.store.scanState().dirty, "扫描收敛")
        XCTAssertEqual(FakePosition.decode(try rig.store.discoveryState()!.position).pairingId, 2, "G 换成新 token 代")
        XCTAssertTrue(rig.logger.contains("discovery cursor expired (3105)"))
        // 之后照常按新 G 发现新照片。
        rig.photo(4, generation: 4)
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [3, 4])
    }

    /// 计数阶段撞上过期：用全量差集给出精确张数，但**不写 G**（计数会被重入，写了会和挂起的那一轮互相覆盖）；
    /// 重置交给下一轮。反证：计数路径里调 resetDiscovery → 这里 G 的 token 代变成 2、扫描被置脏，红。
    func testAnExpiredCursorWhileCountingGivesAnExactCountWithoutTouchingG() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.fakeControl!.pausedFlag = true
        await rig.start()
        rig.media.expireTokens()
        await rig.trigger(.foregroundMediaChange)
        let pending = await rig.pending()
        XCTAssertEqual(pending, 2)
        XCTAssertFalse(try rig.store.scanState().dirty)
        XCTAssertEqual(FakePosition.decode(try rig.store.discoveryState()!.position).pairingId, 1)
        rig.fakeControl!.pausedFlag = false
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2], "这一轮自己发现失效、重置、扫描")
        XCTAssertEqual(FakePosition.decode(try rig.store.discoveryState()!.position).pairingId, 2)
    }

    /// 一轮收尾（审计冲刷，走网络）期间到达的触发不丢：收尾完再跑一轮。
    /// 反证：drain 收尾后不再看队列（Android 现状）→ 这张照片要等下一次外部触发，红。
    func testATriggerArrivingWhileTheCycleIsFinishingIsNotLost() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.afterCycleHold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("first photo confirmed") { (try? rig.state(1)) == .confirmed }
        rig.photo(2, generation: 2)
        let started = await rig.engine.trigger(.mediaChange)
        XCTAssertFalse(started, "收尾期间到达：被合并")
        rig.afterCycleHold.set(false)
        rig.afterCycleGate.open()
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
    }

    /// 照片库身份变了（换库 / 重建）：G 重置、扫描置脏（Android「getVersion 变了」的对位）。
    func testAChangedLibraryIdentityResetsTheCursor() async throws {
        let rig = try Rig()
        let one = rig.photo(1, generation: 1)
        try rig.order(one, .confirmed)
        try rig.advanceG(1)
        rig.photo(2, generation: 1) // 同一代、id 更大：旧 G（整代已过）之下，只有扫描取得到
        try rig.advanceG(1)
        await rig.start()
        rig.media.identity = "lib-2"
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [2])
        XCTAssertEqual(try rig.store.discoveryState()?.libraryIdentity, "lib-2")
    }

    /// iOS 变体（G 不透明、覆盖写）：一轮之后 G 恰好停在最后一张新照片的位置；遗留 / 补传 / 扫描的提交从不写 G。
    func testDiscoveryOnlyMovesForwardAlongTheSourceOrder() async throws {
        let rig = try Rig()
        let legacy = rig.photo(1, generation: 50)
        try rig.order(legacy, .transferring)
        rig.photo(2, generation: 5)
        rig.photo(3, generation: 7)
        rig.photo(4, generation: 7)
        let seen = Locked<[Int64]>([])
        rig.delivery.onStart.set { _ in seen.update { $0.append(try! rig.generation()) } }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2, 3, 4])
        XCTAssertEqual(seen.get(), [0, 0, 5, 7], "每张开始时 G 停在上一张新照片处；遗留 #1（第 50 代）没有把 G 推过去")
        let end = FakePosition.decode(try rig.store.discoveryState()!.position)
        XCTAssertEqual(end.generation, 50, "最后发现链走过了 #1 所在的第 50 代（它已有行，被跳过推进）")
    }

    // MARK: #904：G 跨图库静默错位

    /// I-10：G 不精确时，G 以下漏掉的照片在下一个对账轮被扫描找回；非对账触发不扫（不为每次相册变化都全量扫）；
    /// 已确认的照片不重传（按当前行判重）。
    /// 反证：对账轮不按 preciseDiscovery 置脏（只在 3105 时扫）→ 错位漏掉的 #3 永远取不到，红。
    func testAMisplacedCursorIsCaughtByTheNextReconcileRound() async throws {
        let rig = try Rig()
        rig.media.precise.set(false)
        let one = rig.photo(1, generation: 1)
        try rig.order(one, .confirmed)
        rig.photo(3, generation: 3) // 错位：G 已经在它后面，系统也不报 3105
        try rig.advanceG(5)
        await rig.start()
        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.requests.get().count, 0, "非对账轮不扫")
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.delivery.deliveredIds, [3], "对账轮把漏掉的找回来，已确认的 #1 不重传")
        XCTAssertFalse(try rig.store.scanState().dirty)
        await rig.trigger(.periodic)
        XCTAssertEqual(rig.delivery.deliveredIds, [3], "再扫一遍也不重复传")
    }

    /// 对照：G 精确时对账轮不额外扫（错位的那张不会被找回——这正是 PPassMedia 必须报不精确的理由）。
    func testAPreciseCursorIsNotRescannedOnReconcileRounds() async throws {
        let rig = try Rig()
        rig.photo(3, generation: 3)
        try rig.advanceG(5)
        await rig.start()
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
    }

    /// 不精确 + 没有漏网的：对账轮的全量差集为 0，入口当场收掉扫描，不申请租约、不探测。
    func testAnImpreciseCursorWithNothingMissingCostsNoLease() async throws {
        let rig = try Rig()
        rig.media.precise.set(false)
        let one = rig.photo(1, generation: 1)
        try rig.order(one, .confirmed)
        try rig.advanceG(1)
        await rig.start()
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        XCTAssertEqual(rig.probe.calls.get(), 0)
        XCTAssertFalse(try rig.store.scanState().dirty)
    }

    // MARK: 执行租约（iOS 对位 FGS）

    /// 后台时间到期（onLeaseExpired）：停循环、在飞的保持传输中、等待中（EXECUTION_BLOCKED）、受阻原因记「到期」。
    func testAnExpiredLeaseStopsTheLoopAndWaits() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        rig.lease.held.set(false) // 系统收回了执行时间
        await rig.engine.onLeaseExpired()
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        XCTAssertEqual(rig.fakeControl!.wait, .executionBlocked)
        XCTAssertEqual(rig.fakeControl!.block, .expired)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 1)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1)
    }

    /// C-07：每张开始前重检租约——在两张之间租约被收回，不开始下一张。
    func testTheLeaseIsRecheckedBeforeEveryItem() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        rig.delivery.onStart.set { _ in rig.lease.held.set(false) }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1])
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertNil(try rig.current(2))
        XCTAssertEqual(rig.fakeControl!.wait, .executionBlocked)
    }

    // MARK: 重启类（C-02 / C-16，真实 FlowControlStore）

    /// C-02：已暂停 → 杀进程重启（新引擎、新 store 实例，同一个目录）→ 仍暂停；触发只记意图，不计数之外的任何事。
    func testPauseSurvivesARestartAndTriggersDoNothing() async throws {
        let dir = TempDir()
        let control = FlowControlStore(directory: dir.url)
        let rig = try Rig(control: control, directory: dir)
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await rig.engine.pause()
        rig.delivery.release()

        let rebooted = try Rig(control: FlowControlStore(directory: dir.url), directory: dir)
        rebooted.media.put(rig.media.photos[0])
        rebooted.media.put(rig.media.photos[1])
        await rebooted.start()
        for reason in [TriggerReason.processStart, .appForeground, .networkChange, .periodic] { await rebooted.trigger(reason) }
        let view = await rebooted.engine.view
        XCTAssertEqual(view.state, .paused)
        XCTAssertEqual(view.pending, 2)
        XCTAssertEqual(rebooted.lease.acquires.get(), 0)
        XCTAssertEqual(rebooted.probe.calls.get(), 0)
        XCTAssertEqual(rebooted.importer.imported.get(), [])
        XCTAssertEqual(try rebooted.state(1), .transferring, "中断的那张跨重启仍是传输中")
    }

    /// C-16：等待原因跨重启还在，界面显示同一原因。
    func testTheWaitReasonSurvivesARestart() async throws {
        let dir = TempDir()
        let rig = try Rig(control: FlowControlStore(directory: dir.url), directory: dir)
        rig.photo(1, generation: 1)
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        await rig.start()
        await rig.trigger()
        let rebooted = try Rig(control: FlowControlStore(directory: dir.url), directory: dir)
        let view = await rebooted.engine.view
        XCTAssertEqual(view.state, .waiting)
        XCTAssertEqual(view.waitReason, .wifi)
    }

    // MARK: 唤醒（C409 / C439 / #762）

    /// 每种等待原因登记的唤醒：要用户动手的不登记；Wi‑Fi / 电量登记约束唤醒；其余走探测梯。
    func testEveryWaitReasonRegistersTheRightWake() {
        for reason in WaitReason.allCases {
            switch wakePlanOf(reason) {
            // #1069：手机上的 P-Pass 太旧只能等用户更新。
            case .awaitsUser: XCTAssertTrue([.notPaired, .disabled, .phoneOutdated].contains(reason), "\(reason)")
            case let .whenConditionsMet(r): XCTAssertEqual(r, reason); XCTAssertTrue([.wifi, .battery].contains(reason))
            case .retryProbes: XCTAssertFalse([.notPaired, .disabled, .wifi, .battery, .phoneOutdated].contains(reason))
            }
        }
    }

    /// #762：一次故障只排一组探测；成功一张之后清掉标记并撤掉剩余探测，下一次故障重新排。
    func testOneOutageSchedulesOneLadderAndASuccessResetsIt() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.probe.result.set(.unreachable)
        await rig.start()
        await rig.trigger()
        await rig.trigger(.unreachableProbe)
        await rig.trigger(.unreachableProbe)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 1)
        rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: nil, capabilities: []))
        await rig.trigger(.unreachableProbe)
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertEqual(rig.scheduler.probesCancelled.get(), 1)
        XCTAssertFalse(rig.fakeControl!.ladderSpent)
        rig.photo(2, generation: 2)
        rig.probe.result.set(.unreachable)
        await rig.trigger()
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 2, "新的一次故障")
    }

    /// C-04：仅 Wi‑Fi 却在蜂窝上 → 不申请租约、等待中、登记带约束的唤醒。
    func testWifiOnlyOnCellularWaitsWithAConstraintWake() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        await rig.start()
        await rig.trigger(.foregroundMediaChange)
        XCTAssertEqual(rig.lease.acquires.get(), 0)
        XCTAssertEqual(rig.scheduler.constraintWakes.get(), [.wifi])
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .wifi)
    }

    /// 网络变化时仅 Wi‑Fi 已不满足 → 停掉在跑的循环（在飞的保持传输中）。
    func testANetworkChangeToCellularStopsTheRunningLoop() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.conditions.set(Conditions(wifiOnly: true))
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        await rig.engine.onNetworkChanged()
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(rig.fakeControl!.wait, .wifi)
        XCTAssertEqual(rig.scheduler.constraintWakes.get(), [.wifi])
    }

    /// 空闲时网络变化 → 当作一次 NETWORK_CHANGE 触发，把积压的跑完（对位 Android onNetworkChanged 的非停轮分支）。
    /// 反证：onNetworkChanged 空闲时直接返回 → 一张都没传，红。
    func testANetworkChangeWhileIdleTriggersARound() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.engine.onNetworkChanged()
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.delivery.deliveredIds, [1])
        XCTAssertEqual(try rig.state(1), .confirmed)
    }

    /// 仅 Wi‑Fi 停轮后，网络换回 Wi‑Fi：条件满足，onNetworkChanged 把循环叫醒、续传同一张。
    func testComingBackToWifiAfterAWifiStopResumesTheSameItem() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.conditions.set(Conditions(wifiOnly: true))
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        rig.conditions.set(Conditions(wifiOnly: true, onUnmetered: false))
        await rig.engine.onNetworkChanged()
        XCTAssertEqual(rig.fakeControl!.wait, .wifi)
        rig.delivery.hold.set(false)
        rig.conditions.set(Conditions(wifiOnly: true))
        await rig.engine.onNetworkChanged()
        await rig.engine.awaitIdle()
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertEqual(try rig.current(1)?.attempts, 0, "停轮不算失败")
    }

    /// 断网后网络回来：order 仍可续传，onNetworkChanged 触发的一轮把它传完。
    func testTheItemStoppedByNetworkLossResumesWhenTheNetworkReturns() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await rig.engine.onNetworkLost()
        XCTAssertEqual(try rig.state(1), .transferring)
        rig.delivery.hold.set(false)
        await rig.engine.onNetworkChanged()
        await rig.engine.awaitIdle()
        XCTAssertEqual(try rig.state(1), .confirmed)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
    }

    /// 没有在跑的循环时断网：什么都不做（对位 Android `cycleJob?.isActive != true → return`）。
    func testLosingTheNetworkWhileIdleIsANoOp() async throws {
        let rig = try Rig()
        await rig.start()
        await rig.engine.onNetworkLost()
        XCTAssertNil(rig.fakeControl!.wait)
        XCTAssertEqual(rig.scheduler.unreachableProbes.get(), 0)
    }

    /// #439：前台心跳只在「桌面不可达」或「探测本身报不健康」的等待里叫醒循环；iCloud 原图的等待不叫醒。
    func testTheForegroundHeartbeatWakesOnlyDesktopWaits() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.probe.result.set(.unreachable)
        await rig.start()
        await rig.trigger()
        rig.probe.result.set(.reachable(advertisedPairingId: "e1", health: nil, capabilities: []))
        await rig.engine.onDesktopReachable()
        await rig.engine.awaitIdle()
        XCTAssertEqual(try rig.state(1), .confirmed)

        rig.photo(2, generation: 2)
        rig.importer.iCloudOffline.set([mid(2)])
        await rig.trigger()
        let probes = rig.probe.calls.get()
        await rig.engine.onDesktopReachable()
        await rig.engine.awaitIdle()
        XCTAssertEqual(rig.probe.calls.get(), probes, "iCloud 等的是互联网，不是桌面")
    }

    // MARK: AUDIT-07：轮的身份

    /// 进程被杀留下的未闭合轮：启动时补终态（不带计数）；新一轮的逐张事实都挂同一个 round_id，终态在后；暂停决策挂被打断的那一轮。
    func testRoundIdentityIsDurableAndEveryItemFactCarriesIt() async throws {
        let rig = try Rig(openRound: "killed-round")
        rig.photo(1, generation: 1)
        await rig.start()
        XCTAssertNil(try rig.store.openRoundId())
        var outbox = try rig.store.pendingAuditAfter(0, limit: 50).map(\.record)
        XCTAssertEqual(outbox.map(\.kind), [AuditKinds.roundFinished])
        XCTAssertEqual(outbox[0].roundId, "killed-round")
        XCTAssertEqual(outbox[0].payload, [:])

        await rig.trigger()
        outbox = try rig.store.pendingAuditAfter(0, limit: 50).map(\.record)
        XCTAssertEqual(outbox.map(\.kind), [AuditKinds.roundFinished, AuditKinds.itemConfirmed, AuditKinds.roundFinished])
        let roundId = try XCTUnwrap(outbox[1].roundId)
        XCTAssertEqual(outbox[2].roundId, roundId)
        XCTAssertEqual(outbox[2].payload, ["confirmed": "1"])
        XCTAssertEqual(outbox[1].payload["itemRef"], "media:\(mid(1))")
        XCTAssertEqual(outbox[1].payload["receiptRef"], "receipt-\(try rig.current(1)!.id)")

        rig.photo(2, generation: 2)
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.mediaChange)
        await eventually("delivery started") { rig.delivery.requests.get().count == 2 }
        let interrupted = try XCTUnwrap(rig.store.openRoundId())
        await rig.engine.pause()
        outbox = try rig.store.pendingAuditAfter(0, limit: 50).map(\.record)
        let pause = try XCTUnwrap(outbox.last)
        XCTAssertEqual(pause.kind, AuditKinds.roundControlled)
        XCTAssertEqual(pause.payload, ["action": "pause"])
        XCTAssertEqual(pause.roundId, interrupted)
        XCTAssertFalse(outbox.contains { $0.kind == AuditKinds.roundFinished && $0.roundId == interrupted }, "一张都没结掉的轮不发终态")
    }

    // MARK: #459：原图还在吗

    /// 完整相册权限下，已确认照片的原图被删 → 打 source_missing（不改状态、不动 updated_at）；恢复 → 清掉。部分授权 → 整步跳过。
    func testSourcePresenceIsReconciledOnlyWithFullAccess() async throws {
        let rig = try Rig()
        let one = rig.photo(1, generation: 1)
        let two = rig.photo(2, generation: 2)
        let o1 = try rig.order(one, .confirmed)
        try rig.order(two, .confirmed)
        try rig.advanceG(2)
        await rig.start()
        rig.media.remove(1)

        rig.fullMediaAccess.set(false)
        await rig.trigger(.appForeground)
        XCTAssertEqual(try rig.store.get(o1.id)?.sourceMissing, false, "部分授权：看不见 ≠ 被删")

        rig.fullMediaAccess.set(true)
        rig.media.existingIdsUnreadable = true
        await rig.trigger(.appForeground)
        XCTAssertEqual(try rig.store.get(o1.id)?.sourceMissing, false, "读不出来：什么都不写")

        rig.media.existingIdsUnreadable = false
        await rig.trigger(.appForeground)
        let marked = try XCTUnwrap(rig.store.get(o1.id))
        XCTAssertTrue(marked.sourceMissing)
        XCTAssertEqual(marked.state, .confirmed, "已确认不可否定")
        XCTAssertEqual(marked.updatedAtMs, o1.updatedAtMs)

        rig.media.put(one)
        await rig.trigger(.appForeground)
        XCTAssertEqual(try rig.store.get(o1.id)?.sourceMissing, false)
    }

    /// O-11：桌面缺、原图也没了 → 原行保持已确认，只记一次 UNRECOVERABLE 审计，不补传。
    func testADesktopMissingPhotoWhoseOriginalIsGoneIsRecordedOnceAndNotReuploaded() async throws {
        let rig = try Rig()
        let p = rig.photo(1, generation: 1)
        let o = try rig.order(p, .confirmed)
        try rig.advanceG(1)
        await rig.start()
        rig.media.remove(1)
        rig.presence.missingOnDesktop.set([p.hash])
        await rig.trigger(.periodic) // 这一轮先打 source_missing，再问桌面
        await rig.trigger(.periodic)
        XCTAssertEqual(try rig.current(1)?.id, o.id)
        XCTAssertEqual(try rig.current(1)?.state, .confirmed)
        XCTAssertEqual(rig.delivery.requests.get().count, 0)
        let unrecoverable = try rig.store.pendingAuditAfter(0, limit: 50).map(\.record).filter { $0.payload["disposition"] == "UNRECOVERABLE" }
        XCTAssertEqual(unrecoverable.count, 1)
    }

    /// 桌面宣布了新的配对代号（同一台桌面重新配对）：交给上层持久化。
    func testAnAdvertisedPairingIdIsHandedUp() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        rig.probe.result.set(.reachable(advertisedPairingId: "e2", health: nil, capabilities: []))
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.advertised.get(), ["e2"])
    }

    /// 媒体 id 用字节序归并、按字节判等：Swift `String ==` 认为相等的两种写法（预组合 é / e + 组合重音）是两张照片。
    /// 其中一张已确认时，另一张仍是待办、照常传。反证：把归并里的 `MediaOrder.same` 换成 `==`，已确认那张的行被当成
    /// 另一张的当前行，待办算成 0、它永远不传，红。
    func testMediaIdsAreComparedByBytesNotByUnicodeEquivalence() async throws {
        let rig = try Rig()
        let composed = FakePhoto(n: 1, modified: 1, size: 1, content: "composed", generation: 1, idOverride: "\u{00E9}")
        let decomposed = FakePhoto(n: 2, modified: 1, size: 1, content: "decomposed", generation: 2, idOverride: "e\u{0301}")
        XCTAssertTrue(composed.mediaId == decomposed.mediaId, "前提：Swift 认为两个 id 相等")
        XCTAssertEqual(composed.sourceVersion, decomposed.sourceVersion)
        rig.media.put(composed)
        rig.media.put(decomposed)
        try rig.order(composed, .confirmed)
        try rig.store.markScanDirty()
        rig.fakeControl!.pausedFlag = true
        await rig.start()
        let pending = await rig.pending()
        XCTAssertEqual(pending, 1, "只有分解写法那张是待办")
        rig.fakeControl!.pausedFlag = false
        await rig.trigger()
        XCTAssertEqual(rig.delivery.requests.get().map(\.contentHash), ["blake3:decomposed"])
        XCTAssertEqual(try rig.store.currentOrders().collect().filter { $0.state == .confirmed }.count, 2)
    }
}
