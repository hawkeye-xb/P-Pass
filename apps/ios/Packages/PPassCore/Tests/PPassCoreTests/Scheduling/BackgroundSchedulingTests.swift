// #340：BGProcessingTask 唤醒计划、执行窗口与一次后台任务的跑法。
import Foundation
import XCTest
@testable import PPassCore

final class BackgroundSchedulingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 没有任何等待时挂的是 5 小时周期兜底：要网、要插电（理由见 BackgroundWakePlanner 文件头）。
    func testTheDefaultRequestIsTheFiveHourFallbackOnPower() {
        let spec = BackgroundWakePlanner.next(BackgroundWakePlan(), now: t0)
        XCTAssertEqual(spec.identifier, "com.hawkeyexb.ppass.backup")
        XCTAssertEqual(spec.reason, .periodic)
        XCTAssertEqual(spec.earliestBeginDate, t0.addingTimeInterval(5 * 3600))
        XCTAssertTrue(spec.requiresNetworkConnectivity)
        XCTAssertTrue(spec.requiresExternalPower)
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
