// #977：前台轻心跳（对位 Android `ForegroundHeartbeat.kt`，PRES-01 / #439 / #466）。
//
// 只在 App 前台跑：进前台立即拍一次，之后每 30 秒一次 `hello`；退后台 / 锁屏即停，不常驻、不做后台心跳。
// 复用 `hello`（唯一对成员与未配对都放行的零数据方法），不新增协议动词。
//
// 一拍的结果（与 Android `applyHeartbeatOutcome` 同一映射）：
// - 桌面应答（ok）→ 记「最近一次可达」并叫醒引擎（引擎只在「等待桌面不可达 / 不健康」时才据此起轮）；
// - 被拒为 not_paired / not_authorized → 配对失效（红卡），不记可达也不记不可达；
// - 其它失败 / 超时 → 记一次不可达，不重试、不告警，等下一拍。
// 与 Android 一致：对端回了别的拒绝文案也算「可达」（对端在答话），只有配对失效单独处理。
import Foundation

/// 心跳往哪里记可达性：「失联 N 天」的口径（`SentinelStore`，对位 Android `SentinelStore`）。
public protocol ReachabilityLedger: Sendable {
    func recordReachable(now: Int64) throws
    func recordUnreachable() throws
}

extension SentinelStore: ReachabilityLedger {}

/// start / stop 是同步的（App 层在 scenePhase 回调里直接调，调用顺序即生效顺序，不会被异步调度打乱）。
public final class ForegroundHeartbeat: @unchecked Sendable {
    /// 30 秒：桌面侧 2 分钟窗口能容 4 拍，锁屏瞬间不误判离线。
    public static let intervalMs: Int64 = 30_000

    private let desktop: FlowDesktop
    private let currentEpoch: @Sendable () -> String?
    private let ledger: ReachabilityLedger
    private let now: @Sendable () -> Int64
    private let onReachable: @Sendable () async -> Void
    private let onPairingLost: @Sendable (_ epoch: String, _ failure: DesktopRejected) async -> Void
    private let logger: CoreLogger
    private let intervalMs: Int64
    private let helloTimeoutMs: Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// [currentEpoch] 为 nil = 没有有效配对（未配对 / 已记失效），这一拍直接跳过。
    public init(desktop: FlowDesktop,
                currentEpoch: @escaping @Sendable () -> String?,
                ledger: ReachabilityLedger,
                now: @escaping @Sendable () -> Int64,
                onReachable: @escaping @Sendable () async -> Void,
                onPairingLost: @escaping @Sendable (_ epoch: String, _ failure: DesktopRejected) async -> Void,
                logger: CoreLogger,
                intervalMs: Int64 = ForegroundHeartbeat.intervalMs,
                helloTimeoutMs: Int64 = 20_000,
                sleep: (@Sendable (Int64) async throws -> Void)? = nil) {
        self.desktop = desktop
        self.currentEpoch = currentEpoch
        self.ledger = ledger
        self.now = now
        self.onReachable = onReachable
        self.onPairingLost = onPairingLost
        self.logger = logger
        self.intervalMs = intervalMs
        self.helloTimeoutMs = helloTimeoutMs
        self.sleep = sleep ?? { try await taskSleepMs($0) }
    }

    /// 前台开始：立即拍一拍，然后每 [intervalMs] 一拍。已在跑则什么都不做。
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.beat()
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.sleep(self.intervalMs) } catch { return }
                if Task.isCancelled { return }
                await self.beat()
            }
        }
    }

    /// 退后台 / 锁屏：停循环，取消挂起中的等待。
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    private func beat() async {
        guard let epoch = currentEpoch() else { return }
        let outcome = await boundedWait(helloTimeoutMs, sleep: sleep) { [desktop] in try await desktop.hello() }
        // 已退后台：这一拍的结果不再有意义（不叫醒引擎、不写账）。
        if Task.isCancelled { return }
        switch outcome {
        case .success?:
            await markReachable()
        case let .failure(rejected as DesktopRejected)?:
            if let key = rejected.msgKey, isPairingLostText(key) {
                logger.log("Heartbeat hello rejected: \(key) → pairing lost")
                await onPairingLost(epoch, rejected)
            } else {
                // 对端在答话，只是拒了别的：算可达（与 Android 同）。
                logger.log("Heartbeat hello rejected: \(rejected.msgKey ?? "nil") (desktop reachable)")
                await markReachable()
            }
        case let .failure(error)?:
            logger.log("Heartbeat hello failed: \(error)")
            markUnreachable()
        case nil:
            logger.log("Heartbeat hello timed out (\(helloTimeoutMs)ms)")
            markUnreachable()
        }
    }

    private func markReachable() async {
        do { try ledger.recordReachable(now: now()) } catch { logger.log("Heartbeat recordReachable failed: \(error)") }
        await onReachable()
    }

    private func markUnreachable() {
        do { try ledger.recordUnreachable() } catch { logger.log("Heartbeat recordUnreachable failed: \(error)") }
    }
}
