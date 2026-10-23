// #1119：被拒即清理的协调器（被动断开，要可靠）。
//
// 心跳、探测、投递应答、`flow.failed` 推送、hello 核对任何一条路径发现「电脑已不认这台手机」，都汇到这里；
// 这里保证：只清一次、只清「被拒的那一条」配对、清完之后迟到的拒绝是空操作。
// 与用户手动断开同一份清理（[DisconnectState] 清单），**不发** `device.unpair`（对方已经不认我们了）。
import Foundation

public final class RejectedPairingCleanup: @unchecked Sendable {
    private let localPairingId: @Sendable () -> String?
    private let announce: @Sendable (_ pairingId: String) async -> Void
    private let clear: @Sendable () async -> Void
    private let logger: CoreLogger
    private let lock = NSLock()
    private var inFlight = false

    /// - localPairingId: 盘上当前那条配对记录的代号（没有记录 = nil）。
    /// - announce: 清理之前给用户的提示（保留现有的「配对已失效」通知）；先于清理，因为清理会删掉配对记录。
    /// - clear: 与手动断开同一份本地清理（停引擎 → 断开清单 → 刷新界面状态）。
    public init(localPairingId: @escaping @Sendable () -> String?,
                announce: @escaping @Sendable (_ pairingId: String) async -> Void,
                clear: @escaping @Sendable () async -> Void,
                logger: CoreLogger) {
        self.localPairingId = localPairingId
        self.announce = announce
        self.clear = clear
        self.logger = logger
    }

    /// [rejectedPairingId]：发起那次请求时手上的代号。返回 true = 这一次真的执行了清理。
    /// 空操作的三种情形：已经在清（并发的另一条路径先到）；盘上没有配对（清完之后迟到的拒绝）；
    /// 盘上的是另一条配对（重新扫码之后迟到的旧拒绝——不能误伤新配对）。
    @discardableResult
    public func handle(rejectedPairingId: String) async -> Bool {
        guard claim(rejectedPairingId) else { return false }
        defer { release() }
        logger.log("pairing rejected by the desktop: cleaning up local pairing state")
        await announce(rejectedPairingId)
        await clear()
        return true
    }

    private func claim(_ rejectedPairingId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight, localPairingId() == rejectedPairingId else { return false }
        inFlight = true
        return true
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        inFlight = false
    }
}
