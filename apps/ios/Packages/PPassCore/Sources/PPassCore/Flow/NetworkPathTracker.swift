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
/// 去重对位 Android `PPassApplication.changed()`：能力回调会成串到达（信号强度等），签名没变就不算一次网络变化。
/// Android 的签名是「网络 id + 是否计流量」；iOS 的 `NWPath` 不暴露网络 id，只能用「可用性 + 昂贵度 + 可用接口名」，
/// 同一接口上换 SSID 看不出来——平台差异，Network.framework 没有提供网络标识的 API。
public struct NetworkPathTracker: Sendable {
    public struct Update: Equatable, Sendable {
        /// 引擎动作；首次回调与签名没变的重复回调为 nil（首次：启动由 `LiveBackend.start` 管，这里再触发一次就是重复）。
        public let action: NetworkPathAction?
        /// 从不可用变回可用（首次回调不算）。
        public let recovered: Bool
    }

    private var satisfied: Bool?
    private var signature: String?
    public init() {}

    public mutating func update(satisfied now: Bool, signature sig: String) -> Update {
        let before = satisfied
        let sameAsLast = sig == signature
        satisfied = now
        signature = sig
        guard let before else { return Update(action: nil, recovered: false) }
        if sameAsLast { return Update(action: nil, recovered: false) }
        return Update(action: now ? .changed : .lost, recovered: !before && now)
    }
}

/// 路径更新 → 副作用的固定顺序（对位 Android `onFlowNetworkChanged`）：先让 provider 重探路径，再交给引擎。
/// 首次回调（`action == nil`）什么都不做。
public func dispatchNetworkPath(
    _ update: NetworkPathTracker.Update,
    providerNetworkChange: () -> Void,
    engineLost: () async -> Void,
    engineChanged: () async -> Void
) async {
    guard let action = update.action else { return }
    providerNetworkChange()
    switch action {
    case .lost: await engineLost()
    case .changed: await engineChanged()
    }
}
