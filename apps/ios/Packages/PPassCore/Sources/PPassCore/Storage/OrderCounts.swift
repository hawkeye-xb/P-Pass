// #973：首页事实的账本读口。读不到必须抛出去让上层成为「无法读取」，**绝不能落成 0**——
// 0 张失败、0 张未完成、「还没成功过」会被首页读成「照片都存好了」。
// 对位 Android `FlowProjection.facts`：那里五个读口都是直接抛，不吞。
import Foundation

public protocol OrderCountReading: AnyObject, Sendable {
    func countCurrentByState(bucketIds: Set<String>?) throws -> [OrderState: Int64]
    func countConfirmedPresent(bucketIds: Set<String>?) throws -> Int64
    func lastConfirmedAtMs() throws -> Int64
    func countSourceMissingSkipped(afterMs: Int64, upToMs: Int64) throws -> Int64
}

public struct OrderCounts: Equatable, Sendable {
    public let byState: [OrderState: Int64]
    public let confirmed: Int64
    public let lastSuccessAt: Int64
    public let missingSourceUnacknowledged: Int64
    public let missingSourceAcknowledged: Int64

    public init(byState: [OrderState: Int64], confirmed: Int64, lastSuccessAt: Int64,
                missingSourceUnacknowledged: Int64, missingSourceAcknowledged: Int64) {
        self.byState = byState
        self.confirmed = confirmed
        self.lastSuccessAt = lastSuccessAt
        self.missingSourceUnacknowledged = missingSourceUnacknowledged
        self.missingSourceAcknowledged = missingSourceAcknowledged
    }

    /// 一次读齐；任何一个读口失败都整体抛出，不给「一部分真值一部分 0」的拼盘。
    public static func read(from store: OrderCountReading, missingSourceAckAt ackAt: Int64, nowMs: Int64) throws -> OrderCounts {
        OrderCounts(
            byState: try store.countCurrentByState(bucketIds: nil),
            confirmed: try store.countConfirmedPresent(bucketIds: nil),
            lastSuccessAt: try store.lastConfirmedAtMs(),
            missingSourceUnacknowledged: try store.countSourceMissingSkipped(afterMs: ackAt, upToMs: nowMs),
            missingSourceAcknowledged: ackAt > 0 ? try store.countSourceMissingSkipped(afterMs: 0, upToMs: ackAt) : 0)
    }
}
