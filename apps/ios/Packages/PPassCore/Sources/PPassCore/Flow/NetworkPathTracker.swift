import Foundation

/// 一次网络路径更新，对引擎的含义。
public enum NetworkPathAction: Equatable, Sendable {
    /// 此刻没有任何可用网络 → `FlowEngine.onNetworkLost()`（对位 Android `onFlowNetworkChanged(lost = true)` 且无默认网络）。
    case lost
    /// 路径还在（可能换了接口 / 昂贵度）→ `FlowEngine.onNetworkChanged()`。
    case changed
}

/// `NWPathMonitor` 的更新 → 引擎动作的纯判定（对位 Android `AndroidFlowRuntime.onFlowNetworkChanged`）。
/// iOS 的路径监听给的是「当前整条路径」而不是单个网络的 onLost，所以「Wi‑Fi↔蜂窝切换时旧网络的 onLost 不算断网」
/// 天然成立：只有整条路径不再 satisfied 才是断网。
public struct NetworkPathTracker: Sendable {
    public struct Update: Equatable, Sendable {
        /// 引擎动作；首次回调为 nil（启动由 `LiveBackend.start` 管，这里再触发一次就是重复）。
        public let action: NetworkPathAction?
        /// 从不可用变回可用（首次回调不算）。
        public let recovered: Bool
    }

    private var satisfied: Bool?
    public init() {}

    public mutating func update(satisfied now: Bool) -> Update {
        defer { satisfied = now }
        guard let before = satisfied else { return Update(action: nil, recovered: false) }
        return Update(action: now ? .changed : .lost, recovered: !before && now)
    }
}
