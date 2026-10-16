// #963：照片页实时刷新的订阅会话（对位 Android `TimelineSubscriptionHolder` SYNC-06 + `nextSubscribeRetry` SYNC-04）。
//
// 生命周期跟前台心跳同一层：`start()`（回前台）开订阅，`stop()`（退后台 / 锁屏）关订阅，后台零网络（PRES-01）。
// 订阅是监听：桌面推一帧 `timeline.invalidated`，就通知上层刷新；桌面在订阅建立时也会立即推一帧当前态，
// 所以回前台 / 重连之后补齐后台期间错过的变化不需要额外再拉一次。
// 断线按 1/2/4/8/15/30 秒退避重连，用完停下来交给用户（手动重试，或前台心跳确认桌面可达时自动恢复）。
// 60 秒兜底 tick 只防真实丢事件，不是主通道。
//
// 这里只管「什么时候开 / 关订阅、断了怎么重连、收到信号通知谁」；信号来了刷新哪些数据由上层决定（App 的 TimelineModel）。
import Foundation

/// 一次订阅断开之后该怎么做（对位 Android `SubscribeRetryDecision`）。
public struct TimelineRetryDecision: Equatable, Sendable {
    public let nextAttempt: Int
    public let exhausted: Bool
    /// 非 nil = 等这么久再重连；nil = 已耗尽，停止静默重试。
    public let delayMs: Int64?
}

public enum TimelineRetryPolicy {
    /// 对位 Android `SUBSCRIBE_RETRY_DELAYS_MS`。
    public static let delaysMs: [Int64] = [1_000, 2_000, 4_000, 8_000, 15_000, 30_000]
    /// 连上并撑过这段时间才断，算一次「曾经连上」，退避从头算（对位 `SUBSCRIBE_WAS_LIVE_MS`）。
    public static let wasLiveMs: Int64 = 5_000
    /// 订阅之外的兜底频率（对位 `FULL_REFRESH_FALLBACK_MS`）。
    public static let fallbackMs: Int64 = 60_000

    public static func next(attempt: Int, wasLive: Bool, delays: [Int64] = delaysMs) -> TimelineRetryDecision {
        let a = wasLive ? 0 : attempt
        if a < delays.count { return TimelineRetryDecision(nextAttempt: a + 1, exhausted: false, delayMs: delays[a]) }
        return TimelineRetryDecision(nextAttempt: a, exhausted: true, delayMs: nil)
    }
}

/// 对位 Android `SubscriptionSessionState`。
public struct TimelineLiveState: Equatable, Sendable {
    public var attempt = 0
    public var exhausted = false
    public var connected = false
    public var hadFailure = false
    /// 订阅被发起的次数（切 tab 不得使其 +1：订阅不属于任何一个页面）。
    public var subscriptionsStarted = 0
    public init() {}
}

/// 页面上的提示，对位 Android `photosTimelineChrome`：配对失效时全部收起（红卡是唯一出路）。
public struct TimelineLiveChrome: Equatable, Sendable {
    public let showReconnecting: Bool
    public let showExhaustedRetry: Bool

    public init(state: TimelineLiveState, pairingLost: Bool) {
        if pairingLost {
            showReconnecting = false
            showExhaustedRetry = false
        } else {
            // 与「耗尽」互斥：耗尽之后不会再是「重连中」。
            showReconnecting = state.hadFailure && !state.connected && !state.exhausted
            showExhaustedRetry = state.exhausted
        }
    }
}

public final class TimelineLive: @unchecked Sendable {
    private let transport: CtrlStreamTransport
    private let isPaired: @Sendable () -> Bool
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let logger: CoreLogger
    private let onInvalidated: @Sendable () -> Void
    private let onFallbackTick: @Sendable () -> Void
    private let onState: @Sendable (TimelineLiveState) -> Void

    private let lock = NSLock()
    private var generation = 0
    private var active = false
    private var state = TimelineLiveState()
    private var sessionTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    public init(transport: CtrlStreamTransport,
                isPaired: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Int64,
                onInvalidated: @escaping @Sendable () -> Void,
                onFallbackTick: @escaping @Sendable () -> Void,
                onState: @escaping @Sendable (TimelineLiveState) -> Void,
                logger: CoreLogger,
                sleep: (@Sendable (Int64) async throws -> Void)? = nil) {
        self.transport = transport
        self.isPaired = isPaired
        self.now = now
        self.onInvalidated = onInvalidated
        self.onFallbackTick = onFallbackTick
        self.onState = onState
        self.logger = logger
        self.sleep = sleep ?? { try await taskSleepMs($0) }
    }

    public var currentState: TimelineLiveState { lock.lock(); defer { lock.unlock() }; return state }

    /// 回前台：开订阅 + 兜底 tick。幂等（重复调用不重启连接）。同步，调用顺序即生效顺序。
    public func start() {
        lock.lock()
        guard !active else { lock.unlock(); return }
        active = true
        generation += 1
        launchLocked(reset: true)
        let s = state
        lock.unlock()
        onState(s)
    }

    /// 退后台 / 锁屏：关订阅、停 tick。之后迟到的帧不再通知上层。
    public func stop() {
        lock.lock()
        active = false
        generation += 1
        sessionTask?.cancel(); sessionTask = nil
        fallbackTask?.cancel(); fallbackTask = nil
        state.connected = false
        let s = state
        lock.unlock()
        onState(s)
    }

    /// 配对变了（新配对 / 断开）：前台时按当前配对重建会话；没有配对就空闲。
    public func pairingChanged() {
        lock.lock()
        guard active else { lock.unlock(); return }
        generation += 1
        sessionTask?.cancel()
        launchLocked(reset: true)
        let s = state
        lock.unlock()
        onState(s)
    }

    /// 手动重试：退避清零重来。
    public func retry() {
        lock.lock()
        guard active else { lock.unlock(); return }
        generation += 1
        sessionTask?.cancel()
        state.attempt = 0
        state.exhausted = false
        launchLocked(reset: false)
        let s = state
        lock.unlock()
        onState(s)
    }

    /// 前台心跳确认桌面可达：只有退避已耗尽才重启（效果同手动重试）；重连中 / 已连上什么都不做，保证幂等。
    public func onDesktopReachable() {
        lock.lock()
        let exhausted = active && state.exhausted
        lock.unlock()
        guard exhausted else { return }
        logger.log("timeline subscribe: auto-resume (desktop reachable after exhausted)")
        retry()
    }

    // MARK: - 内部

    /// 调用方持有锁。
    private func launchLocked(reset: Bool) {
        if reset { state = TimelineLiveState() }
        let gen = generation
        sessionTask = Task { [weak self] in await self?.runSession(gen) }
        if fallbackTask == nil {
            fallbackTask = Task { [weak self] in await self?.runFallback() }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && generation == gen
    }

    /// 只在这一代还有效时改状态并通知；迟到的回调什么都不做。
    @discardableResult
    private func mutate(_ gen: Int, _ change: (inout TimelineLiveState) -> Void) -> Bool {
        lock.lock()
        guard active, generation == gen else { lock.unlock(); return false }
        change(&state)
        let s = state
        lock.unlock()
        onState(s)
        return true
    }

    private func runSession(_ gen: Int) async {
        guard isPaired() else { return } // 未配对：空闲，等 pairingChanged
        while !Task.isCancelled, isCurrent(gen), !currentState.exhausted {
            guard mutate(gen, { $0.subscriptionsStarted += 1; $0.connected = false }) else { return }
            let connectedAt = LockedBox<Int64?>(nil)
            do {
                try await subscribeOnce(gen: gen) { [now] in
                    connectedAt.set(now())
                    self.mutate(gen) { $0.connected = true; $0.hadFailure = false }
                    self.logger.log("timeline subscribe: connected")
                }
                logger.log("timeline subscribe: ended (peer closed)")
            } catch is CancellationError {
                return
            } catch let rejected as SubscribeRejected {
                logger.log("timeline subscribe: rejected by the desktop (\(rejected.code): \(rejected.msgKey))")
            } catch {
                logger.log("timeline subscribe: ended (\(error))")
            }
            if Task.isCancelled || !isCurrent(gen) { return }
            let wasLive = connectedAt.get().map { now() - $0 >= TimelineRetryPolicy.wasLiveMs } ?? false
            var delay: Int64?
            let applied = mutate(gen) { s in
                let d = TimelineRetryPolicy.next(attempt: s.attempt, wasLive: wasLive)
                s.connected = false
                s.hadFailure = true
                s.attempt = d.nextAttempt
                s.exhausted = d.exhausted
                delay = d.delayMs
            }
            guard applied else { return }
            if currentState.exhausted {
                logger.log("timeline subscribe: exhausted (backoff used up), waiting for manual retry or desktop reachable")
            }
            if let delay { do { try await sleep(delay) } catch { return } }
        }
    }

    /// 一条订阅：第一帧是应答（拒绝就抛，确认才算连上），之后每个 `timeline.invalidated` 通知上层一次。
    private func subscribeOnce(gen: Int, onConnected: @escaping @Sendable () -> Void) async throws {
        let first = LockedBox(true)
        try await transport.stream(method: Methods.timelineSubscribe, paramsJSON: Data("{}".utf8)) { [weak self] data in
            guard let self, self.isCurrent(gen) else { return } // 已停 / 已换代：迟到的帧丢掉
            let frame = try ProtoJSON.decode(JSONValue.self, from: data)
            guard case let .object(fields) = frame else { return }
            if first.update({ let was = $0; $0 = false; return was }) {
                if let rejected = ControlPlanePush.rejection(fields) { throw rejected }
                onConnected()
            }
            if case .string("timeline.invalidated")? = fields["event"] { self.onInvalidated() }
        }
    }

    private func runFallback() async {
        while !Task.isCancelled {
            do { try await sleep(TimelineRetryPolicy.fallbackMs) } catch { return }
            if Task.isCancelled { return }
            lock.lock(); let on = active; lock.unlock()
            if on, isPaired() { onFallbackTick() }
        }
    }
}

/// 极小的锁盒子（PPassCore 内部用）。
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    @discardableResult
    func update<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}
