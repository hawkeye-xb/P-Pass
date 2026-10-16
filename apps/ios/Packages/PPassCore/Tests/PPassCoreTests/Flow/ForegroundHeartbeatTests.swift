// #977：前台心跳（对位 Android `ForegroundHeartbeat` + `applyHeartbeatOutcome`）。
// 时间用可拨动的睡眠，不靠真实等待；账本是真实的 SentinelStore（临时目录）。
import Foundation
import XCTest
@testable import PPassCore

/// 虚拟时间的睡眠：`sleep` 挂起，`advance` 把时钟拨过去，到点的醒来；被取消的立刻抛。
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64 = 0
    private var waiters: [UUID: (ms: Int64, deadline: Int64, cont: CheckedContinuation<Void, Error>)] = [:]

    /// 正在等 [ms] 毫秒的睡眠数（`boundedWait` 的超时哨兵不取消、会残留到期，所以按时长区分心跳间隔与超时）。
    func pending(ms: Int64) -> Int { lock.lock(); defer { lock.unlock() }; return waiters.values.filter { $0.ms == ms }.count }

    func sleep(_ ms: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                waiters[id] = (ms, now + ms, c)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let w = waiters.removeValue(forKey: id)
            lock.unlock()
            w?.cont.resume(throwing: CancellationError())
        }
    }

    func advance(_ ms: Int64) {
        lock.lock()
        now += ms
        let due = waiters.filter { $0.value.deadline <= now }
        due.keys.forEach { waiters.removeValue(forKey: $0) }
        lock.unlock()
        due.values.forEach { $0.cont.resume() }
    }
}

final class ForegroundHeartbeatTests: XCTestCase {
    private final class Rig: @unchecked Sendable {
        let tmp = TempDir()
        let desktop = FakeDesktop()
        let sleeper = ManualSleeper()
        let clock = ManualClock(5_000_000)
        let epoch = Locked<String?>("e1")
        let wakes = Locked(0)
        let lost = Locked<[String]>([])
        let logger = RecordingLogger()
        lazy var sentinel = SentinelStore(directory: tmp.url, logger: logger)
        lazy var heartbeat = ForegroundHeartbeat(
            desktop: desktop, currentEpoch: { [epoch] in epoch.get() }, ledger: sentinel, now: clock.function,
            onReachable: { [wakes] in wakes.update { $0 += 1 } },
            onPairingLost: { [lost] epoch, _ in lost.update { $0.append(epoch) } },
            logger: logger, sleep: { [sleeper] in try await sleeper.sleep($0) })
    }

    /// 给「不该发生」的断言留一点真实时间，让错发的那一拍有机会冒出来。
    private func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }

    func testStartBeatsImmediatelyThenEvery30Seconds() async {
        let r = Rig()
        r.heartbeat.start()
        await eventually("立即一拍") { r.desktop.helloCalls.get() == 1 }
        await eventually("在等下一拍") { r.sleeper.pending(ms: 30_000) == 1 }
        r.sleeper.advance(29_999)
        await settle()
        XCTAssertEqual(r.desktop.helloCalls.get(), 1, "29.999 秒还没到")
        r.sleeper.advance(1)
        await eventually("第 30 秒") { r.desktop.helloCalls.get() == 2 }
        await eventually("再次进入等待") { r.sleeper.pending(ms: 30_000) == 1 }
        r.sleeper.advance(30_000)
        await eventually("第 60 秒") { r.desktop.helloCalls.get() == 3 }
        r.heartbeat.stop()
    }

    func testStartIsIdempotent() async {
        let r = Rig()
        r.heartbeat.start()
        r.heartbeat.start()
        await eventually { r.desktop.helloCalls.get() == 1 }
        await settle()
        XCTAssertEqual(r.desktop.helloCalls.get(), 1)
        r.heartbeat.stop()
    }

    func testStopEndsTheLoopAndAFreshStartBeatsImmediatelyAgain() async {
        let r = Rig()
        r.heartbeat.start()
        await eventually { r.sleeper.pending(ms: 30_000) == 1 }
        r.heartbeat.stop()
        await eventually("挂起的等待被取消") { r.sleeper.pending(ms: 30_000) == 0 }
        r.sleeper.advance(120_000)
        await settle()
        XCTAssertEqual(r.desktop.helloCalls.get(), 1, "退后台后不再拍")
        r.heartbeat.start()
        await eventually("回前台立即拍") { r.desktop.helloCalls.get() == 2 }
        r.heartbeat.stop()
    }

    func testSuccessRecordsReachableAndWakesTheEngine() async throws {
        let r = Rig()
        try r.sentinel.recordUnreachable()
        r.heartbeat.start()
        await eventually { r.wakes.get() == 1 }
        XCTAssertEqual(r.sentinel.load(), SentinelState(lastReachableAt: 5_000_000, failedAttempts: 0, lastNotifiedAt: 0), "可达时间写入、失败计数清零")
        XCTAssertTrue(r.lost.get().isEmpty)
        r.heartbeat.stop()
    }

    func testRejectedAsNotPairedOrNotAuthorizedReportsPairingLostForThatEpoch() async throws {
        for key in ["err.not_paired", "err.not_authorized"] {
            let r = Rig()
            r.desktop.helloResult.set(.failure(DesktopRejected(msgKey: key, method: "hello")))
            r.heartbeat.start()
            await eventually(key) { r.lost.get() == ["e1"] }
            await settle()
            XCTAssertEqual(r.wakes.get(), 0, "配对失效不叫醒引擎")
            XCTAssertEqual(r.sentinel.load(), SentinelState(), "既不记可达也不记不可达")
            r.heartbeat.stop()
        }
    }

    func testAnyOtherFailureCountsAsUnreachableAndNeverWakesTheEngine() async throws {
        let r = Rig()
        try r.sentinel.recordReachable(now: 42)
        r.desktop.helloResult.set(.failure(URLError(.cannotConnectToHost)))
        r.heartbeat.start()
        await eventually { r.sentinel.load().failedAttempts == 1 }
        XCTAssertEqual(r.sentinel.load().lastReachableAt, 42, "失败不动可达时间")
        XCTAssertEqual(r.wakes.get(), 0)
        XCTAssertTrue(r.lost.get().isEmpty)
        XCTAssertTrue(r.logger.contains("Heartbeat hello failed"), "失败要留日志，不静默")

        // 桌面恢复：下一拍接上并叫醒。
        r.desktop.helloResult.set(.success(Hello(pairingEpoch: "e1")))
        await eventually { r.sleeper.pending(ms: 30_000) == 1 }
        r.clock.now = 6_000_000
        r.sleeper.advance(30_000)
        await eventually("恢复后叫醒") { r.wakes.get() == 1 }
        XCTAssertEqual(r.sentinel.load(), SentinelState(lastReachableAt: 6_000_000, failedAttempts: 0, lastNotifiedAt: 0))
        r.heartbeat.stop()
    }

    func testAHelloThatNeverAnswersIsBoundedAndCountsAsUnreachable() async {
        let r = Rig()
        r.desktop.helloHang.set(true)
        r.heartbeat.start()
        await eventually("挂起的 hello") { r.desktop.helloCalls.get() == 1 && r.sleeper.pending(ms: 20_000) == 1 }
        r.sleeper.advance(20_000)
        await eventually("超时记不可达") { r.sentinel.load().failedAttempts == 1 }
        XCTAssertEqual(r.wakes.get(), 0)
        XCTAssertTrue(r.logger.contains("timed out"))
        r.heartbeat.stop()
    }

    func testARejectionOtherThanPairingLostStillMeansTheDesktopAnswered() async {
        let r = Rig()
        r.desktop.helloResult.set(.failure(DesktopRejected(msgKey: "err.busy", method: "hello")))
        r.heartbeat.start()
        await eventually { r.wakes.get() == 1 }
        XCTAssertEqual(r.sentinel.load().lastReachableAt, 5_000_000)
        XCTAssertTrue(r.lost.get().isEmpty)
        r.heartbeat.stop()
    }

    func testNoValidPairingSkipsTheBeatWithoutTouchingTheNetwork() async {
        let r = Rig()
        r.epoch.set(nil)
        r.heartbeat.start()
        await eventually("进入等待") { r.sleeper.pending(ms: 30_000) == 1 }
        await settle()
        XCTAssertEqual(r.desktop.helloCalls.get(), 0)
        XCTAssertEqual(r.sentinel.load(), SentinelState())
        r.heartbeat.stop()
    }

    func testAnAnswerThatArrivesAfterStopIsDiscarded() async {
        let r = Rig()
        r.desktop.helloHang.set(true)
        r.heartbeat.start()
        await eventually { r.desktop.helloCalls.get() == 1 }
        r.heartbeat.stop()
        r.desktop.releaseHello() // 应答在退后台之后才到
        await settle()
        XCTAssertEqual(r.wakes.get(), 0, "退后台后不叫醒引擎")
        XCTAssertEqual(r.sentinel.load(), SentinelState())
    }
}
