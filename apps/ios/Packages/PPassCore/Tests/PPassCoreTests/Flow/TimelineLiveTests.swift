// #963：照片页实时订阅会话（对位 Android `TimelineSubscriptionHolder` / `SubscribeRetryTest`）。
// 时间用可拨动的睡眠，不靠真实等待。
import Foundation
import XCTest
@testable import PPassCore

private let ack = #"{"id":"x","ok":true,"result":{"subscribed":true}}"#
private let invalidated = #"{"event":"timeline.invalidated","data":{}}"#

/// 每次 `stream` 调用按顺序取一个剧本；用完后重复最后一个。
private final class ScriptedLive: CtrlStreamTransport, @unchecked Sendable {
    enum Script {
        /// 交付这些帧后挂着，直到被取消。
        case hold([String])
        /// 交付这些帧后正常结束（对端关闭）。
        case end([String])
        /// 交付这些帧后抛错。
        case fail([String])
    }
    struct Boom: Error {}

    let scripts: [Script]
    let opens = Locked(0)
    let cancelled = Locked(0)
    /// 每次打开时拿到的 onFrame，测试里用来「停了之后再注入帧」。
    let handlers = Locked<[@Sendable (Data) throws -> Void]>([])

    init(_ scripts: [Script]) { self.scripts = scripts }

    func stream(method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws {
        XCTAssertEqual(method, Methods.timelineSubscribe)
        let n = opens.update { $0 += 1; return $0 }
        handlers.update { $0.append(onFrame) }
        let script = scripts[min(n - 1, scripts.count - 1)]
        switch script {
        case .hold(let frames):
            for f in frames { try onFrame(Data(f.utf8)) }
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled.update { $0 += 1 }; throw error }
        case .end(let frames):
            for f in frames { try onFrame(Data(f.utf8)) }
        case .fail(let frames):
            for f in frames { try onFrame(Data(f.utf8)) }
            throw Boom()
        }
    }

    func inject(_ index: Int, _ frame: String) {
        let h = handlers.get()
        try? h[index](Data(frame.utf8))
    }
}

final class TimelineLiveTests: XCTestCase {
    private final class Rig: @unchecked Sendable {
        let sleeper = ManualSleeper()
        let clock = ManualClock(1_000)
        let paired = Locked(true)
        let invalidations = Locked(0)
        let ticks = Locked(0)
        let states = Locked<[TimelineLiveState]>([])
        let logger = RecordingLogger()
        let transport: ScriptedLive
        lazy var live = TimelineLive(
            transport: transport, isPaired: { [paired] in paired.get() }, now: clock.function,
            onInvalidated: { [invalidations] in invalidations.update { $0 += 1 } },
            onFallbackTick: { [ticks] in ticks.update { $0 += 1 } },
            onState: { [states] s in states.update { $0.append(s) } },
            logger: logger, sleep: { [sleeper] in try await sleeper.sleep($0) })

        init(_ scripts: [ScriptedLive.Script]) { transport = ScriptedLive(scripts) }
        var state: TimelineLiveState { live.currentState }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }

    // MARK: 退避策略（Android SubscribeRetryTest 同款）

    func testRetryPolicyWalksTheLadderThenExhausts() {
        var attempt = 0
        var delays: [Int64] = []
        while true {
            let d = TimelineRetryPolicy.next(attempt: attempt, wasLive: false)
            guard let delay = d.delayMs else {
                XCTAssertTrue(d.exhausted)
                XCTAssertEqual(d.nextAttempt, 6, "耗尽时档位停在最后")
                break
            }
            delays.append(delay)
            attempt = d.nextAttempt
        }
        XCTAssertEqual(delays, [1_000, 2_000, 4_000, 8_000, 15_000, 30_000])
    }

    func testRetryPolicyWasLiveRestartsTheLadder() {
        let d = TimelineRetryPolicy.next(attempt: 5, wasLive: true)
        XCTAssertEqual(d, TimelineRetryDecision(nextAttempt: 1, exhausted: false, delayMs: 1_000))
        XCTAssertTrue(TimelineRetryPolicy.next(attempt: 6, wasLive: false).exhausted, "没连上过：不重置")
        XCTAssertFalse(TimelineRetryPolicy.next(attempt: 6, wasLive: true).exhausted, "连上过：即使档位用完也重来")
    }

    func testChromeMirrorsAndroidPhotosTimelineChrome() {
        var s = TimelineLiveState()
        XCTAssertEqual(TimelineLiveChrome(state: s, pairingLost: false), .init(state: s, pairingLost: false))
        XCTAssertFalse(TimelineLiveChrome(state: s, pairingLost: false).showReconnecting, "从没失败过：沉默")
        s.hadFailure = true
        XCTAssertTrue(TimelineLiveChrome(state: s, pairingLost: false).showReconnecting)
        s.connected = true
        XCTAssertFalse(TimelineLiveChrome(state: s, pairingLost: false).showReconnecting, "连上了就收起")
        s.connected = false; s.exhausted = true
        let c = TimelineLiveChrome(state: s, pairingLost: false)
        XCTAssertTrue(c.showExhaustedRetry)
        XCTAssertFalse(c.showReconnecting, "与耗尽互斥")
        let lost = TimelineLiveChrome(state: s, pairingLost: true)
        XCTAssertFalse(lost.showExhaustedRetry, "配对失效：红卡是唯一出路")
        XCTAssertFalse(lost.showReconnecting)
    }

    // MARK: 会话

    func testAckConnectsAndEveryInvalidatedSignalsOnce() async {
        let r = Rig([.hold([ack, invalidated, invalidated, #"{"event":"flow.delivered","data":{"queue_sequence":1}}"#, #"{"no_event":true}"#])])
        r.live.start()
        await eventually("两次信号") { r.invalidations.get() == 2 }
        await settle()
        XCTAssertEqual(r.invalidations.get(), 2, "flow.* 与无 event 的帧不触发刷新")
        XCTAssertTrue(r.state.connected)
        XCTAssertFalse(r.state.hadFailure)
        XCTAssertEqual(r.state.subscriptionsStarted, 1)
        r.live.stop()
    }

    func testStartIsIdempotent() async {
        let r = Rig([.hold([ack])])
        r.live.start(); r.live.start()
        await eventually { r.transport.opens.get() == 1 }
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 1)
        XCTAssertEqual(r.state.subscriptionsStarted, 1, "重复 start（如多次回前台事件）不重启连接")
        r.live.stop()
    }

    func testRejectedAckIsAFailureNotAConnection() async {
        let r = Rig([.end([#"{"id":"x","ok":false,"error":{"code":"NOT_AUTHORIZED","reason":"not_paired"}}"#, invalidated])])
        r.live.start()
        await eventually("进入退避等待") { r.sleeper.pending(ms: 1_000) == 1 }
        XCTAssertFalse(r.state.connected)
        XCTAssertTrue(r.state.hadFailure)
        XCTAssertEqual(r.invalidations.get(), 0, "被拒的订阅不能触发刷新")
        XCTAssertTrue(r.logger.lines.contains { $0.contains("rejected by the desktop") && $0.contains("NOT_AUTHORIZED") })
        r.live.stop()
    }

    func testBackoffLadderThenExhaustedAndNoSilentRetryAfter() async {
        let r = Rig([.fail([])])
        r.live.start()
        for delay in TimelineRetryPolicy.delaysMs {
            await eventually("等 \(delay)ms") { r.sleeper.pending(ms: delay) == 1 }
            XCTAssertFalse(r.state.exhausted)
            r.sleeper.advance(delay)
        }
        await eventually("耗尽") { r.state.exhausted }
        XCTAssertEqual(r.transport.opens.get(), 7, "首次 + 6 次重连")
        XCTAssertEqual(r.state.subscriptionsStarted, 7)
        r.sleeper.advance(3_600_000)
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 7, "耗尽后不再静默重试")
        XCTAssertTrue(TimelineLiveChrome(state: r.state, pairingLost: false).showExhaustedRetry)
        r.live.stop()
    }

    func testManualRetryAfterExhaustedRestartsFromTheBottomOfTheLadder() async {
        let r = Rig([.fail([])])
        r.live.start()
        for delay in TimelineRetryPolicy.delaysMs {
            await eventually { r.sleeper.pending(ms: delay) == 1 }
            r.sleeper.advance(delay)
        }
        await eventually { r.state.exhausted }
        r.live.retry()
        await eventually("重新发起一次订阅") { r.transport.opens.get() == 8 }
        await eventually("退避从 1 秒重来") { r.sleeper.pending(ms: 1_000) == 1 }
        XCTAssertFalse(r.state.exhausted)
        r.live.stop()
    }

    func testDesktopReachableOnlyResumesWhenExhausted() async {
        // 反证面：没耗尽时（已连上 / 重连中）调用不得重启——否则每 30 秒心跳都会掀翻一条好好的订阅。
        let r = Rig([.hold([ack])])
        r.live.start()
        await eventually { r.state.connected }
        r.live.onDesktopReachable()
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 1, "已连上：什么都不做")
        r.live.stop()

        let e = Rig([.fail([])])
        e.live.start()
        for delay in TimelineRetryPolicy.delaysMs {
            await eventually { e.sleeper.pending(ms: delay) == 1 }
            e.live.onDesktopReachable() // 重连中：不动
            e.sleeper.advance(delay)
        }
        await eventually { e.state.exhausted }
        XCTAssertEqual(e.transport.opens.get(), 7, "重连中调用不额外起订阅")
        e.live.onDesktopReachable()
        await eventually("耗尽后桌面回来：自动恢复") { e.transport.opens.get() == 8 }
        e.live.onDesktopReachable()
        await settle()
        XCTAssertEqual(e.transport.opens.get(), 8, "恢复后的下一拍心跳是 no-op（幂等）")
        e.live.stop()
    }

    func testConnectedStateClearsFailureFlagAndKeepsLadderUntilWasLive() async {
        // 第 1 条失败（档位 → 1），第 2 条连上：hadFailure 清掉；档位要等「撑过 5 秒才断」才回零。
        let r = Rig([.fail([]), .hold([ack])])
        r.live.start()
        await eventually { r.sleeper.pending(ms: 1_000) == 1 }
        XCTAssertTrue(r.state.hadFailure)
        r.sleeper.advance(1_000)
        await eventually { r.state.connected }
        XCTAssertFalse(r.state.hadFailure)
        XCTAssertEqual(r.state.attempt, 1)
        r.live.stop()
    }

    func testWasLiveDropRestartsLadderAtOneSecond() async {
        // 用可控的断开时机：订阅连上、时钟走过 5 秒、再让它结束。
        final class Gate: CtrlStreamTransport, @unchecked Sendable {
            let clock: ManualClock
            let opens = Locked(0)
            let release = Locked<CheckedContinuation<Void, Never>?>(nil)
            init(clock: ManualClock) { self.clock = clock }
            func stream(method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws {
                let n = opens.update { $0 += 1; return $0 }
                if n == 1 { throw ScriptedLive.Boom() } // 先攒一档
                try onFrame(Data(ack.utf8))
                await withCheckedContinuation { c in release.set(c) }
            }
        }
        let clock = ManualClock(1_000)
        let sleeper = ManualSleeper()
        let gate = Gate(clock: clock)
        let live = TimelineLive(transport: gate, isPaired: { true }, now: clock.function, onInvalidated: {}, onFallbackTick: {},
                                onState: { _ in }, logger: NoopLogger(), sleep: { try await sleeper.sleep($0) })
        live.start()
        await eventually { sleeper.pending(ms: 1_000) == 1 }
        sleeper.advance(1_000)
        await eventually("第二条连上") { live.currentState.connected }
        clock.now += 5_000
        gate.release.get()?.resume()
        await eventually("连上过 5 秒后断：退避回到 1 秒档") { sleeper.pending(ms: 1_000) == 1 }
        XCTAssertEqual(live.currentState.attempt, 1)
        live.stop()
    }

    // MARK: 生命周期

    func testStopCancelsTheStreamAndLateFramesAreIgnored() async {
        let r = Rig([.hold([ack])])
        r.live.start()
        await eventually { r.state.connected }
        r.transport.inject(0, invalidated)
        XCTAssertEqual(r.invalidations.get(), 1)
        r.live.stop()
        await eventually("流被取消（后台零连接）") { r.transport.cancelled.get() == 1 }
        XCTAssertFalse(r.state.connected)
        r.transport.inject(0, invalidated) // 反证：迟到的帧不得再通知上层
        r.transport.inject(0, invalidated)
        XCTAssertEqual(r.invalidations.get(), 1, "退后台之后不再触发刷新")
    }

    func testStopThenAdvancingTimeOpensNoConnectionAndNoFallbackTick() async {
        let r = Rig([.fail([])])
        r.live.start()
        await eventually { r.sleeper.pending(ms: 1_000) == 1 }
        r.live.stop()
        await eventually("退避等待被取消") { r.sleeper.pending(ms: 1_000) == 0 }
        r.sleeper.advance(600_000)
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 1, "后台不重连")
        XCTAssertEqual(r.ticks.get(), 0, "后台不兜底拉取")
    }

    func testForegroundAgainOpensAFreshSubscription() async {
        let r = Rig([.hold([ack])])
        r.live.start()
        await eventually { r.state.connected }
        r.live.stop()
        r.live.start()
        await eventually("回前台重建订阅") { r.transport.opens.get() == 2 }
        await eventually { r.state.connected }
        XCTAssertEqual(r.state.subscriptionsStarted, 1, "新前台会话：状态清零重来")
        r.live.stop()
    }

    func testFallbackTickEverySixtySecondsWhilePaired() async {
        let r = Rig([.hold([ack])])
        r.live.start()
        await eventually { r.sleeper.pending(ms: 60_000) == 1 }
        r.sleeper.advance(59_999)
        await settle()
        XCTAssertEqual(r.ticks.get(), 0)
        r.sleeper.advance(1)
        await eventually("第 60 秒") { r.ticks.get() == 1 }
        await eventually { r.sleeper.pending(ms: 60_000) == 1 }
        r.paired.set(false)
        r.sleeper.advance(60_000)
        await eventually { r.sleeper.pending(ms: 60_000) == 1 }
        XCTAssertEqual(r.ticks.get(), 1, "未配对不拉取")
        r.live.stop()
    }

    func testUnpairedStaysIdleUntilPairingChanges() async {
        let r = Rig([.hold([ack])])
        r.paired.set(false)
        r.live.start()
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 0, "未配对：不开订阅")
        r.paired.set(true)
        r.live.pairingChanged()
        await eventually("配对后开订阅") { r.transport.opens.get() == 1 }
        await eventually { r.state.connected }
        r.paired.set(false)
        r.live.pairingChanged()
        await eventually("断开配对：旧订阅被取消") { r.transport.cancelled.get() == 1 }
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 1, "没有配对不重开")
        r.live.stop()
    }

    func testPairingChangedWhileBackgroundedDoesNothing() async {
        let r = Rig([.hold([ack])])
        r.live.pairingChanged()
        await settle()
        XCTAssertEqual(r.transport.opens.get(), 0, "后台不连")
    }
}
