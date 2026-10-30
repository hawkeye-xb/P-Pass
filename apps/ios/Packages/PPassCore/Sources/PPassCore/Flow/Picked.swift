// #1272 挑几张传（iOS）：手选的照片单独存，不进 order 表 / 范围 / 对账。
// 照片本身不落盘：PHPicker 给回的 itemProvider 只在本进程里有效，每次只加载正在传的那一张（见 App 侧的手选导入器）。
// 进程被杀 = 内存里的这批没了；只有「批次汇总」写在磁盘上，下次打开据此提示「上次挑的 N 张有 M 张没传完」。
import Foundation

/// 手选一张的来源句柄（App 侧是 NSItemProvider 的包装）。PPassCore 不认识它的内容，只原样交给导入器。
public protocol PickedPayload: Sendable {}

public enum PickedState: String, Codable, Sendable {
    case open, transferring, delivered, alreadyThere, failed
}

public struct PickedItem: Sendable {
    public let id: Int64
    public let fileName: String
    public let mimeType: String
    public let payload: PickedPayload

    /// 交给传输层的 queue_sequence：与 order 行 id 隔开（同 Android `SEQUENCE_BASE`）。
    public var queueSequence: Int64 { PickedQueue.sequenceBase + id }
}

/// 一批手选的汇总：结果句、进度行、「被杀后提示」都读它。
public struct PickedBatchSummary: Codable, Equatable, Sendable {
    public var total: Int
    public var delivered: Int
    public var alreadyThere: Int
    public var failed: Int
    /// 进程被杀时这一批还没传完：下次打开读到的。
    public var interrupted: Bool

    public var settled: Int { delivered + alreadyThere + failed }
    public var open: Int { max(0, total - settled) }
    /// 「没传完」：被杀后提示里的张数 = 没送达的（含已记失败的）。
    public var notReached: Int { total - delivered - alreadyThere }
}

/// 引擎看到的手选存取（取件 / 记结局）。
public protocol PickedStore: Sendable {
    func hasOpen() -> Bool
    /// 下一张要传的（open 或被打断留在 transferring 的），没有 = nil。
    func nextOpen() -> PickedItem?
    func mark(_ id: Int64, _ state: PickedState)
}

/// 进程内的手选队列 + 落盘的批次汇总。线程安全。
public final class PickedQueue: PickedStore, @unchecked Sendable {
    public static let fileName = "picked_batch.json"
    /// queue_sequence 起点（1<<40）：与 order 行 id 不相撞。
    public static let sequenceBase: Int64 = 1 << 40
    public static let maxPick = 100

    private struct Ledger: Codable {
        var nextId: Int64
        var batch: PickedBatchSummary?
    }

    private struct Entry {
        var item: PickedItem
        var state: PickedState
    }

    private let url: URL
    private let logger: CoreLogger
    private let lock = NSLock()
    private var ledger: Ledger
    private var entries: [Entry] = []
    private var changed: (@Sendable () -> Void)?

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
        var loaded = JSONFile.read(Ledger.self, url, logger: logger) ?? Ledger(nextId: 1, batch: nil)
        // 新进程：上一进程没传完的批次只剩汇总（句柄随进程没了）——标成被打断。
        if var batch = loaded.batch, batch.open > 0 {
            batch.interrupted = true
            loaded.batch = batch
            try? JSONFile.write(loaded, url)
        }
        ledger = loaded
    }

    /// 汇总有变化时通知（UI 刷新）。
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); changed = handler; lock.unlock()
    }

    /// 登记新的一批（最多 [maxPick] 张）。旧批的汇总被替换；旧批没传完的句柄丢弃。返回收下的张数。
    @discardableResult
    public func addBatch(_ payloads: [(fileName: String, mimeType: String, payload: PickedPayload)]) -> Int {
        let taken = Array(payloads.prefix(Self.maxPick))
        guard !taken.isEmpty else { return 0 }
        lock.lock()
        entries = taken.map { p in
            let id = ledger.nextId
            ledger.nextId += 1
            return Entry(item: PickedItem(id: id, fileName: p.fileName, mimeType: p.mimeType, payload: p.payload), state: .open)
        }
        ledger.batch = PickedBatchSummary(total: taken.count, delivered: 0, alreadyThere: 0, failed: 0, interrupted: false)
        persistLocked()
        let notify = changed
        lock.unlock()
        notify?()
        return taken.count
    }

    public func summary() -> PickedBatchSummary? {
        lock.lock(); defer { lock.unlock() }
        return ledger.batch
    }

    public func hasOpen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.contains { $0.state == .open || $0.state == .transferring }
    }

    public func nextOpen() -> PickedItem? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.state == .open || $0.state == .transferring }?.item
    }

    public func mark(_ id: Int64, _ state: PickedState) {
        lock.lock()
        guard let i = entries.firstIndex(where: { $0.item.id == id }) else { lock.unlock(); return }
        let was = entries[i].state
        entries[i].state = state
        if was != state, var batch = ledger.batch {
            switch state {
            case .delivered: batch.delivered += 1
            case .alreadyThere: batch.alreadyThere += 1
            case .failed: batch.failed += 1
            case .open, .transferring: break
            }
            ledger.batch = batch
            if state != .transferring && state != .open { persistLocked() }
        }
        let notify = changed
        lock.unlock()
        notify?()
    }

    /// 断开 / 重新配对：清空队列与汇总（序号计数保留，免得下次与桌面上残留的 tuple 撞号）。
    public func clearAll() {
        lock.lock()
        entries = []
        ledger.batch = nil
        persistLocked()
        let notify = changed
        lock.unlock()
        notify?()
    }

    private func persistLocked() {
        do { try JSONFile.write(ledger, url) } catch { logger.log("picked: ledger write failed (\(error))") }
    }
}
