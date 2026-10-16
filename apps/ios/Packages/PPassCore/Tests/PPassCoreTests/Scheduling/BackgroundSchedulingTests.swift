// #340：BGProcessingTask 唤醒计划、执行窗口与一次后台任务的跑法。
import Foundation
import XCTest
@testable import PPassCore

final class BackgroundSchedulingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 没有任何等待时挂的是 5 小时周期兜底：要网、不要求插电（理由见 BackgroundWakePlanner 文件头）。
    func testTheDefaultRequestIsTheFiveHourFallbackWithoutPower() {
        let spec = BackgroundWakePlanner.next(BackgroundWakePlan(), now: t0)
        XCTAssertEqual(spec.identifier, "com.hawkeyexb.ppass.backup")
        XCTAssertEqual(spec.reason, .periodic)
        XCTAssertEqual(spec.earliestBeginDate, t0.addingTimeInterval(5 * 3600))
        XCTAssertTrue(spec.requiresNetworkConnectivity)
        XCTAssertFalse(spec.requiresExternalPower)
    }

    /// 约束唤醒优先：Wi‑Fi → 尽快、要网、不要求插电；电量 → 要插电（iOS 能表达的最接近「电量不低」的条件）。
    func testConstraintWakesTakePriority() {
        let wifi = BackgroundWakePlanner.next(BackgroundWakePlan(probeRung: 0, probeAnchor: t0.timeIntervalSince1970, constraint: "WIFI"), now: t0)
        XCTAssertEqual(wifi.reason, .constraintsMet)
        XCTAssertNil(wifi.earliestBeginDate)
        XCTAssertFalse(wifi.requiresExternalPower)
        let battery = BackgroundWakePlanner.next(BackgroundWakePlan(constraint: "BATTERY"), now: t0)
        XCTAssertTrue(battery.requiresExternalPower)
    }

    /// 探测梯：10 / 20 / 40 / 80 分钟（与 Android 同值），每跑一拍走下一拍，4 拍走完回到周期兜底。
    func testTheProbeLadderWalksFourRungsThenFallsBackToPeriodic() {
        var plan = BackgroundWakePlan(probeRung: 0, probeAnchor: t0.timeIntervalSince1970)
        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            let spec = BackgroundWakePlanner.next(plan, now: now)
            XCTAssertEqual(spec.reason, .unreachableProbe)
            XCTAssertFalse(spec.requiresExternalPower)
            delays.append(spec.earliestBeginDate!.timeIntervalSince(now))
            now = spec.earliestBeginDate!
            plan = BackgroundWakePlanner.afterRun(plan, ran: .unreachableProbe, now: now)
        }
        XCTAssertEqual(delays, [600, 1200, 2400, 4800])
        XCTAssertNil(plan.probeRung)
        XCTAssertEqual(BackgroundWakePlanner.next(plan, now: now).reason, .periodic)
    }

    /// 引擎登记的唤醒合进计划、落盘、重新挂请求；梯子没走完不重排（KEEP）；成功时撤梯子；计划跨「进程重启」读回。
    func testThePlannedSchedulerMergesEngineWakesAndPersists() {
        let dir = TempDir()
        let submitter = RecordingSubmitter()
        let clock = Locked(t0)
        let s = PlannedWakeScheduler(directory: dir.url, submitter: submitter, logger: NoopLogger(), now: { clock.get() })
        s.ensureScheduled()
        XCTAssertEqual(submitter.last?.reason, .periodic)
        s.scheduleUnreachableProbes()
        XCTAssertEqual(submitter.last?.reason, .unreachableProbe)
        XCTAssertEqual(submitter.last?.earliestBeginDate, t0.addingTimeInterval(600))
        clock.set(t0.addingTimeInterval(300))
        s.scheduleUnreachableProbes()
        XCTAssertEqual(submitter.last?.earliestBeginDate, t0.addingTimeInterval(600), "梯子没走完不重排")
        let reborn = PlannedWakeScheduler(directory: dir.url, submitter: submitter, logger: NoopLogger(), now: { clock.get() })
        XCTAssertEqual(reborn.plan.probeRung, 0, "后台启动是新进程：计划要从盘上读回")
        reborn.scheduleWhenConditionsMet(.wifi)
        XCTAssertEqual(submitter.last?.reason, .constraintsMet)
        reborn.didRun(.constraintsMet)
        XCTAssertEqual(submitter.last?.reason, .unreachableProbe, "约束用掉之后回到梯子")
        reborn.cancelUnreachableProbes()
        XCTAssertEqual(submitter.last?.reason, .periodic)
        reborn.scheduleWhenConditionsMet(.desktopUnreachable)
        XCTAssertEqual(submitter.last?.reason, .periodic, "只有 Wi‑Fi / 电量是约束唤醒")
        reborn.stop()
        XCTAssertEqual(submitter.cancels.get(), 1)
        XCTAssertEqual(reborn.plan, BackgroundWakePlan())
    }

    /// 系统拒绝提交（模拟器 / 没开后台 App 刷新）：不抛、说实话（日志），前台补捞照常。
    func testARefusedSubmitIsLoggedNotThrown() {
        let dir = TempDir()
        let submitter = RecordingSubmitter()
        submitter.refuse.set(true)
        let logger = RecordingLogger()
        PlannedWakeScheduler(directory: dir.url, submitter: submitter, logger: logger).ensureScheduled()
        XCTAssertTrue(logger.contains("submit refused"))
    }

    /// 执行窗口：前台 / 收尾时间 / 后台任务任一开着才持有；全部关掉之后 isHeld 立即为 false（C-07 每张前重检会退出）。
    func testTheExecutionWindowIsHeldOnlyWhileSomeTimeIsOpen() async {
        let w = ExecutionWindow()
        let none = await w.acquire()
        XCTAssertFalse(none)
        w.setAppActive(true)
        let fg = await w.acquire()
        XCTAssertTrue(fg)
        XCTAssertTrue(w.isHeld())
        w.setAppActive(false)
        w.setFinishingTime(true)
        XCTAssertTrue(w.isHeld(), "退到后台但还有收尾时间")
        w.setFinishingTime(false)
        XCTAssertFalse(w.isHeld())
    }
}

final class BackgroundRunTests: XCTestCase {

    /// 验收 3（E2 一半）：系统给到窗口 → 打开执行窗口 → 用计划里的原因叫醒引擎 → 跑完一轮 → 关窗口 → 重新挂下一条请求。
    func testABackgroundTaskRunsOneRoundInsideItsWindow() async throws {
        let dir = TempDir()
        let window = ExecutionWindow()
        let submitter = RecordingSubmitter()
        let scheduler = PlannedWakeScheduler(directory: dir.url, submitter: submitter, logger: NoopLogger())
        let rig = try Rig(directory: dir, lease: window, scheduler: scheduler)
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.requests.get().count, 0, "App 在后台、没有执行时间：拿不到租约")
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .executionBlocked)
        let reason = BackgroundWakePlanner.next(scheduler.plan, now: Date()).reason
        let ok = await BackgroundRun.run(engine: rig.engine, window: window, scheduler: scheduler, reason: reason)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.delivery.deliveredIds, [1])
        XCTAssertFalse(window.hasExecutionTime)
        XCTAssertNotNil(submitter.last, "跑完重新挂下一条")
    }

    /// 系统收回后台时间（expirationHandler）：引擎停下、在飞的那张保持传输中不计次、等待中（EXECUTION_BLOCKED），这一轮报不成功。
    func testAnExpiredBackgroundTaskStopsTheLoopWithoutCounting() async throws {
        let dir = TempDir()
        let window = ExecutionWindow()
        let scheduler = PlannedWakeScheduler(directory: dir.url, submitter: RecordingSubmitter(), logger: NoopLogger())
        let rig = try Rig(directory: dir, lease: window, scheduler: scheduler)
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        let run = Task { await BackgroundRun.run(engine: rig.engine, window: window, scheduler: scheduler, reason: .periodic) }
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await BackgroundRun.expire(engine: rig.engine, window: window)
        let ok = await run.value
        XCTAssertFalse(ok)
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 1)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .executionBlocked)
    }
}

/// #958：短任务窗口（第 4 种执行窗口）：20 秒自收尾、只传照片。
final class ShortTaskWindowTests: XCTestCase {
    func testPhotosOnlyHoldsOnlyWhileTheShortTaskIsTheSoleWindow() {
        let w = ExecutionWindow()
        XCTAssertFalse(w.photosOnly)
        w.setShortTask(true)
        XCTAssertTrue(w.photosOnly)
        XCTAssertTrue(w.hasExecutionTime)
        for set in [{ w.setAppActive(true) }, { w.setFinishingTime(true) }, { w.setBackgroundTask(true) }] {
            set()
            XCTAssertFalse(w.photosOnly, "任一其他窗口开着就不是只传照片")
            w.setAppActive(false); w.setFinishingTime(false); w.setBackgroundTask(false)
            XCTAssertTrue(w.photosOnly)
        }
        w.setShortTask(false)
        XCTAssertFalse(w.photosOnly)
    }

    private func makeRig(_ name: String = #function) throws -> (Rig, ExecutionWindow) {
        let window = ExecutionWindow()
        let rig = try Rig(name, lease: window)
        return (rig, window)
    }

    /// 只开短任务窗口：照片照常处理；新视频建一行待传输（不带 hash、不计次数、不进跳过名单），游标越过它；不空转；
    /// 之后长任务窗口来了照常把视频传完。
    func testOnlyTheShortWindowSendsPhotosAndLeavesNewVideosPending() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1, video: true)
        rig.photo(2, generation: 2)
        rig.photo(3, generation: 3, video: true)
        rig.photo(4, generation: 4)
        await rig.start()
        let ok = await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.delivery.deliveredIds, [2, 4])
        for n in [1, 3] {
            XCTAssertEqual(try rig.state(n), .pending)
            XCTAssertEqual(try rig.current(n)?.attempts, 0)
            XCTAssertNil(try rig.current(n)?.contentHash)
            XCTAssertFalse(try rig.store.isSkipped(mid(n)))
        }
        XCTAssertEqual(rig.importer.imported.get().count, 2, "视频一次都没读")
        XCTAssertEqual(try rig.generation(), 4, "游标越过了视频，不挡后面的照片")
        XCTAssertFalse(window.hasExecutionTime)

        // 再来一次短任务：没有新东西，视频仍原样，不空转。
        _ = await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger)
        XCTAssertEqual(rig.importer.imported.get().count, 2)

        // 长任务窗口来了：视频照常处理。
        window.setBackgroundTask(true)
        await rig.trigger(.periodic)
        window.setBackgroundTask(false)
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2, 3, 4])
    }

    /// 短任务默认用 MEDIA_CHANGE：只做增量发现，不做全量对账（不查源文件、不置脏扫描、不调 reconcileSourcePresence），
    /// 新照片仍经 G 游标被处理；对账留给 PERIODIC 等长任务 / 前台。
    func testTheShortTaskDiscoversIncrementallyAndSkipsReconcile() async throws {
        let (rig, window) = try makeRig()
        let old = rig.photo(1, generation: 1)
        let o1 = try rig.order(old, .confirmed)
        try rig.advanceG(1)
        await rig.start()
        rig.media.remove(1) // 对账轮才会把它打成 source_missing
        rig.photo(2, generation: 2)
        let callsBefore = rig.media.existingIdsCalls.get()

        let ok = await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.delivery.deliveredIds, [2], "新照片经增量发现被处理")
        XCTAssertEqual(rig.media.existingIdsCalls.get(), callsBefore, "没有源文件存在性查询")
        XCTAssertEqual(try rig.store.get(o1.id)?.sourceMissing, false, "没有对账：没打 source_missing")
        XCTAssertFalse(try rig.store.scanState().dirty, "没有置脏扫描")
        XCTAssertFalse(rig.logger.lines.contains { $0.contains("source_missing:") })

        // 对照：同一个库里 PERIODIC 确实会对账，说明上面的断言能抓到对账。
        await rig.trigger(.periodic)
        XCTAssertEqual(try rig.store.get(o1.id)?.sourceMissing, true)
    }

    /// 已有的待传输 / 传输中视频：只开短任务窗口时状态原样（不改状态、不加次数），照片照常；本轮不重复取同一张。
    func testExistingVideoOrdersStayAsTheyAreUnderTheShortWindow() async throws {
        let (rig, window) = try makeRig()
        let v1 = rig.photo(1, generation: 1, video: true)
        let v2 = rig.photo(2, generation: 2, video: true)
        let p3 = rig.photo(3, generation: 3)
        try rig.order(v1, .pending)
        try rig.order(v2, .transferring)
        try rig.order(p3, .pending)
        try rig.advanceG(3)
        await rig.start()
        _ = await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger)
        XCTAssertEqual(rig.delivery.deliveredIds, [3])
        XCTAssertEqual(try rig.state(1), .pending)
        XCTAssertEqual(try rig.state(2), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        XCTAssertEqual(try rig.current(2)?.attempts, 0)
        XCTAssertTrue(rig.importer.imported.get().allSatisfy { $0 == p3.mediaId })
        XCTAssertFalse(try rig.store.isSkipped(v1.mediaId))
    }

    /// 前台窗口同时开着：视频照常处理（不是只传照片）。
    func testVideosAreProcessedWhenAnotherWindowIsOpen() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1, video: true)
        rig.photo(2, generation: 2)
        await rig.start()
        window.setAppActive(true)
        window.setShortTask(true)
        XCTAssertFalse(window.photosOnly)
        await rig.trigger(.periodic)
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2])
        window.setShortTask(false)
    }

    /// 计时到点走与系统到期相同的收尾：在飞的那张保持传输中、不计次数、等待中（EXECUTION_BLOCKED）。
    func testTheBudgetExpiresTheShortTaskLikeASystemExpiry() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        await rig.start()
        rig.delivery.hold.set(true)
        let ok = await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger, budget: 0.1)
        XCTAssertTrue(ok)
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(try rig.current(1)?.attempts, 0)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 1)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .executionBlocked)
        XCTAssertFalse(window.hasExecutionTime)
    }

    /// 评审 bug：短任务跑着、用户打开 App——计时到点只关短任务自己的窗口，前台还开着，这一轮不能被停；
    /// 之后的照片和视频（此时不再只传照片）继续处理。
    func testTheShortBudgetDoesNotStopARoundThatTheForegroundKeepsOpen() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2, video: true)
        rig.photo(3, generation: 3)
        await rig.start()
        rig.delivery.hold.set(true)
        let run = Task { await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger, budget: 0.3) }
        await eventually("first delivery started") { rig.delivery.requests.get().count == 1 }
        window.setAppActive(true)
        try await Task.sleep(nanoseconds: 600_000_000) // 计时已到点
        XCTAssertTrue(window.hasExecutionTime, "前台窗口仍开着")
        XCTAssertEqual(rig.delivery.cancelled.get().count, 0, "在飞的那张没被取消")
        rig.delivery.release()
        let ok = await run.value // 到点就返回，不等这一轮
        XCTAssertTrue(ok)
        await rig.engine.awaitIdle()
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2, 3])
        let view = await rig.engine.view
        XCTAssertNotEqual(view.waitReason, .executionBlocked)
    }

    /// 长任务到期、前台还开着：只关长任务自己，这一轮不停。
    func testALongTaskExpiryDoesNotStopARoundThatTheForegroundKeepsOpen() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        window.setAppActive(true)
        window.setBackgroundTask(true)
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.periodic)
        await eventually("delivery started") { rig.delivery.requests.get().count == 1 }
        await BackgroundRun.expire(engine: rig.engine, window: window)
        XCTAssertTrue(window.hasExecutionTime)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 0)
        rig.delivery.release()
        await rig.engine.awaitIdle()
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2])
        let view = await rig.engine.view
        XCTAssertNotEqual(view.waitReason, .executionBlocked)
    }

    /// 叠加：宽限期开着时启动短任务 → 宽限期先到期 → 只剩短任务窗口，photosOnly 变 true：视频保持原状、照片照常；
    /// 计时到点收尾，在飞的那张保持传输中。
    func testAGraceWindowExpiringLeavesTheShortWindowPhotosOnly() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2, video: true)
        rig.photo(3, generation: 3)
        await rig.start()
        let delivery = rig.delivery
        delivery.onStart.set { r in if r.details.snapshot.mediaId == mid(3) { delivery.hold.set(true) } }
        window.setFinishingTime(true)
        delivery.hold.set(true)
        let run = Task { await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger, budget: 0.8) }
        await eventually("first delivery started") { delivery.requests.get().count == 1 }
        XCTAssertEqual(window.openSourcesExceptShort, ["finishing"])
        await BackgroundRun.expireFinishingTime(engine: rig.engine, window: window)
        XCTAssertTrue(window.photosOnly)
        XCTAssertEqual(delivery.cancelled.get().count, 0, "短任务窗口还开着，这一轮不停")
        delivery.release()
        await eventually("photo 3 started") { delivery.requests.get().count == 2 }
        XCTAssertEqual(delivery.deliveredIds, [1, 3])
        XCTAssertEqual(try rig.state(2), .pending, "视频保持原状")
        XCTAssertFalse(rig.importer.imported.get().contains(mid(2)))
        let ok = await run.value
        XCTAssertTrue(ok)
        XCTAssertEqual(try rig.state(3), .transferring)
        XCTAssertEqual(try rig.current(3)?.attempts, 0)
        XCTAssertEqual(delivery.cancelled.get().count, 1)
    }

    /// 叠加：前台开着时启动短任务 → 计时到点 → runShort 返回（不等前台那一轮），这一轮没被停，前台继续跑。
    func testTheShortTaskReturnsAtTheBudgetWhileTheForegroundRoundKeepsRunning() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        window.setAppActive(true)
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.appForeground)
        await eventually("foreground round in flight") { rig.delivery.requests.get().count == 1 }
        let ok = await BackgroundRun.runShort(engine: rig.engine, window: window, logger: rig.logger, budget: 0.2)
        XCTAssertTrue(ok, "到点就返回，不等前台那一轮")
        XCTAssertTrue(rig.logger.lines.contains { $0.contains("others=[\"foreground\"]") }, "叠加运行，日志记下其他窗口")
        XCTAssertTrue(rig.logger.lines.contains { $0.contains("finish=budget") })
        XCTAssertFalse(window.photosOnly)
        XCTAssertTrue(window.hasExecutionTime)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 0)
        rig.delivery.release()
        await rig.engine.awaitIdle()
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2])
        let view = await rig.engine.view
        XCTAssertNotEqual(view.waitReason, .executionBlocked)
    }

    // MARK: #1007 到期以引擎重读租约为准

    /// 过时的到期：宽限期关掉、到期信号还在路上时用户回了前台、前台一轮已开跑——信号送到时还有执行时间，这一轮不停。
    func testAStaleExpiryDoesNotStopTheForegroundRound() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2)
        await rig.start()
        window.setFinishingTime(true)
        window.setFinishingTime(false) // 宽限期到期：只关自己；到期信号异步送往引擎
        window.setAppActive(true) // 信号送到之前：回前台
        rig.delivery.hold.set(true)
        await rig.engine.onAppForeground()
        await eventually("foreground round in flight") { rig.delivery.requests.get().count == 1 }
        await rig.engine.onLeaseExpired() // 过时的信号现在才送到
        XCTAssertEqual(rig.delivery.cancelled.get().count, 0, "前台持有执行时间，在飞的那张不取消")
        rig.delivery.release()
        await rig.engine.awaitIdle()
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2])
        let view = await rig.engine.view
        XCTAssertNotEqual(view.waitReason, .executionBlocked)
    }

    /// 停的过程中回前台：确实没有执行时间、引擎开始停；等在飞那张退出时用户回前台并触发 APP_FOREGROUND——
    /// 停完之后还有执行时间、有触发，接着跑，不卡在 EXECUTION_BLOCKED。
    func testAForegroundArrivingWhileStoppingRunsAgain() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        await rig.start()
        window.setFinishingTime(true)
        rig.delivery.hold.set(true)
        let engine: FlowEngine = rig.engine, delivery = rig.delivery
        delivery.onCancel.set { _ in
            delivery.onCancel.set { _ in }
            delivery.hold.set(false)
            window.setAppActive(true)
            await engine.onAppForeground()
        }
        await engine.trigger(.networkChange)
        await eventually("grace round in flight") { delivery.requests.get().count == 1 }
        await BackgroundRun.expireFinishingTime(engine: engine, window: window)
        XCTAssertEqual(delivery.cancelled.get().count, 1, "确实没有执行时间：停了")
        await eventually("ran again after the stop") { delivery.requests.get().count == 2 }
        await engine.awaitIdle()
        XCTAssertEqual(try rig.state(1), .confirmed)
        let view = await engine.view
        XCTAssertNotEqual(view.waitReason, .executionBlocked)
    }

    /// 反证对照：真到期（没有任何窗口开着）仍然停、在飞的保持传输中、等待中。
    func testAGenuineExpiryStillStops() async throws {
        let (rig, window) = try makeRig()
        rig.photo(1, generation: 1)
        await rig.start()
        window.setFinishingTime(true)
        rig.delivery.hold.set(true)
        await rig.engine.trigger(.networkChange)
        await eventually("grace round in flight") { rig.delivery.requests.get().count == 1 }
        await BackgroundRun.expireFinishingTime(engine: rig.engine, window: window)
        XCTAssertFalse(window.hasExecutionTime)
        XCTAssertEqual(try rig.state(1), .transferring)
        XCTAssertEqual(rig.delivery.cancelled.get().count, 1)
        let view = await rig.engine.view
        XCTAssertEqual(view.waitReason, .executionBlocked)
    }
}
