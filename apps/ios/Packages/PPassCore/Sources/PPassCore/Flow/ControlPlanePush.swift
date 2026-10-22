// #963：`timeline.subscribe` 推送源的真实实现（对位 Android `DaemonClient.subscribeTimeline` + `SubscribeAck.kt`）。
// 订阅是监听：发一次请求，之后桌面推一帧才处理一帧，不轮询。
import Foundation

/// 桌面拒绝了这次订阅（第一帧就是 `ok:false` 的应答），例如设备未配对时的 `NOT_AUTHORIZED`。
public struct SubscribeRejected: Error, Equatable, Sendable {
    public let code: String
    public let reason: DesktopReason
}

/// [FlowPushSource] 的控制面实现：一条 `timeline.subscribe` 流。
/// 第一帧是应答：被拒就抛 [SubscribeRejected]、不调 onConnected；确认才调一次 onConnected。
/// 之后只把带 `data` 的 `flow.delivered` / `flow.failed` 交给 onEvent（桌面已按手机过滤，到这里的都是这台手机的）；
/// `timeline.invalidated` 与没有 `event` 键的帧忽略。
public struct ControlPlanePush: FlowPushSource {
    public let transport: CtrlStreamTransport

    public init(transport: CtrlStreamTransport) { self.transport = transport }

    public func subscribe(onConnected: @escaping @Sendable () -> Void, onEvent: @escaping @Sendable (String, JSONValue) -> Void) async throws {
        let first = FirstFrame()
        try await transport.stream(method: Methods.timelineSubscribe, paramsJSON: Data("{}".utf8)) { data in
            let frame = try ProtoJSON.decode(JSONValue.self, from: data)
            guard case let .object(fields) = frame else { return }
            if first.claim() {
                if let rejected = Self.rejection(fields) { throw rejected }
                onConnected()
            }
            guard case let .string(event)? = fields["event"] else { return }
            if event == "flow.delivered" || event == "flow.failed", let payload = fields["data"], case .object = payload {
                onEvent(event, payload)
            }
        }
    }

    /// 只认显式的 `ok:false` 且不是推送帧。
    static func rejection(_ fields: [String: JSONValue]) -> SubscribeRejected? {
        guard fields["event"] == nil, fields["ok"] == .bool(false) else { return nil }
        var code = "", reason = ""
        if case let .object(error)? = fields["error"] {
            if case let .string(c)? = error["code"] { code = c }
            if case let .string(r)? = error["reason"] { reason = r }
        }
        return SubscribeRejected(code: code, reason: DesktopReason(wire: reason))
    }
}

private final class FirstFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if seen { return false }
        seen = true
        return true
    }
}
