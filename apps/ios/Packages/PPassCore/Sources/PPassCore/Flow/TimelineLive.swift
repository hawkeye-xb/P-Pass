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

/// #1904（对位 Android #1883）：手机与电脑之间**唯一**的连接状态——存储电脑详情页与照片页都从这里取文案与
/// 显示条件，同一时刻不可能给出相反结论。
///
/// 词汇表对齐桌面 `crates/transport/src/conninfo.rs` 的 `ConnectionStatus`（Direct / Relay / Offline / Unknown），
/// 另加一档「配对已失效」：那是另一个维度（配对还有没有效），不是连接状态本身。
///
/// 手机侧不区分直连与中继——实时订阅只知道「连上没有」，路径分类只存在于诊断探测里，拿不到就不编：
/// 连上就是 `.connected`。
public struct ConnectionState: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 配对已失效（桌面吊销 / 移除本设备）——重新扫码连接是唯一出路。
        case pairingLost
        /// 实时连上了（直连或中继）。
        case connected
        /// 断过、正在退避重连。
        case reconnecting
        /// 退避耗尽：没有实时连接。
        case offline
        /// 还没有依据（刚进前台、这次订阅还没连上）。
        case unknown
    }

    public let status: Status
    /// 距上次确认可达的天数（`SentinelStore.lastReachableAt` 推算）；nil = 从未确认过，不编天数。
    public let daysUnreachable: Int?

    public init(status: Status, daysUnreachable: Int? = nil) {
        self.status = status
        self.daysUnreachable = daysUnreachable
    }

    /// 「已连接」这种强断言只能在真的有连接时用——两页共用这一条判定。
    public var isConnected: Bool { status == .connected }

    /// 配对已失效：两页都收起各自的提示，只留「重新扫码连接」这一条出路。
    public var needsRepair: Bool { status == .pairingLost }
}

/// #1904（对位 Android #1883 `connectionStateOf`）：把三份信号合成唯一状态——配对有效性、实时订阅会话、
/// 失联天数。配对有效性是另一个维度，优先；其余按订阅会话判定。
///
/// 顺序即优先级：配对已失效 > 已连上 > 退避耗尽（断开）> 重连中 > 未知。
/// 「已连上」排在「退避耗尽」前面——真的连上了就是连上了，即便上一轮的退避记录还在。
public func connectionStateOf(
    pairingLost: Bool,
    state: TimelineLiveState,
    daysUnreachable: Int? = nil
) -> ConnectionState {
    let status: ConnectionState.Status
    if pairingLost {
        status = .pairingLost
    } else if state.connected {
        status = .connected
    } else if state.exhausted {
        status = .offline
    } else if state.hadFailure {
        status = .reconnecting
    } else {
        status = .unknown
    }
    return ConnectionState(status: status, daysUnreachable: daysUnreachable)
}

/// 页面上的提示，对位 Android `photosTimelineChrome`：配对失效时全部收起（红卡是唯一出路）。
public struct TimelineLiveChrome: Equatable, Sendable {
    public let showReconnecting: Bool
    public let showExhaustedRetry: Bool

    /// #1904：从唯一连接状态取——重连中 / 断开两档由同一个事实源决定，与存储电脑详情页同源。
    public init(connection: ConnectionState) {
        showReconnecting = connection.status == .reconnecting
        showExhaustedRetry = connection.status == .offline
    }

    public init(state: TimelineLiveState, pairingLost: Bool = false) {
        self.init(connection: connectionStateOf(pairingLost: pairingLost, state: state))
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
                logger.log("timeline subscribe: rejected by the desktop (\(rejected.code): \(rejected.reason))")
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
