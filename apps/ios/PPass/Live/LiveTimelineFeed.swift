import Foundation
import PPassCore

/// 照片页实时更新的真实现（#963）：把 PPassCore 的 `TimelineLive`（订阅会话 + 退避 + 兜底 tick）接给页面。
/// 生命周期由 LiveBackend 管（setActive / 配对变化 / 心跳可达），页面只观察。
final class LiveTimelineFeed: TimelineLiveFeed, @unchecked Sendable {
    private(set) var session: TimelineLive!
    @MainActor private var observers: [UUID: @MainActor (TimelineLiveEvent) -> Void] = [:]
    @MainActor private var latest = TimelineLiveState()

    init(transport: CtrlStreamTransport, isPaired: @escaping @Sendable () -> Bool, logger: CoreLogger) {
        session = TimelineLive(
            transport: transport, isPaired: isPaired, now: { Int64(Date().timeIntervalSince1970 * 1000) },
            onInvalidated: { [weak self] in self?.emit(.invalidated) },
            onFallbackTick: { [weak self] in self?.emit(.fallbackTick) },
            onState: { [weak self] state in self?.emit(.state(state)) },
            logger: logger)
    }

    private func emit(_ event: TimelineLiveEvent) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .state(let s) = event { latest = s }
            for handler in observers.values { handler(event) }
        }
    }

    @MainActor func observe(_ handler: @escaping @MainActor (TimelineLiveEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(.state(latest))
        return token
    }

    @MainActor func remove(_ token: UUID) { observers[token] = nil }
    @MainActor func retry() { session.retry() }
}
