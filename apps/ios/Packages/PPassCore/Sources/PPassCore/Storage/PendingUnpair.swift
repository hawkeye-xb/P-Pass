// #956：断开时电脑离线 / 手机无网，`device.unpair` 只发一次就丢，电脑侧留下一台「幽灵手机」。
// 标准做法是 outbox：断开前先把「要撤销」这件事落盘，有触发点（回前台 / 网络恢复 / 启动）就重试，成功或过期即删。
//
// - 条目自带投递所需的全部信息（peerToken、pairingEpoch），不依赖已被清掉的 pairing.json；发送仍用本机身份密钥。
// - 成功、或电脑回「不认识这台手机」（NOT_AUTHORIZED：已被移除 / 吊销，目的已达成）都删条目；其余失败保留。
// - 创建满 7 天丢弃。重新配对同一台电脑时先删该电脑的条目（见 [PendingUnpairStore.remove]），否则重试会把新配对撤掉。
// - 日志不写 peerToken：只写 [LogRedact.id] 的 hash 前缀。
import Foundation

public struct PendingUnpair: Codable, Equatable, Sendable {
    public var daemonNodeId: String
    public var peerToken: String
    /// 要结束的那一次配对（#565：电脑按纪元条件吊销）。空 = 旧配对，不带纪元。
    public var pairingEpoch: String
    public var createdAtMs: Int64

    public init(daemonNodeId: String, peerToken: String, pairingEpoch: String, createdAtMs: Int64) {
        self.daemonNodeId = daemonNodeId
        self.peerToken = peerToken
        self.pairingEpoch = pairingEpoch
        self.createdAtMs = createdAtMs
    }
}

/// `pending_unpair.json`（存储根）。每台电脑最多一条（按 daemonNodeId 去重，后写覆盖）。损坏 = 空队列，并记一行日志。
public final class PendingUnpairStore: @unchecked Sendable {
    public static let fileName = "pending_unpair.json"
    private let url: URL
    private let logger: CoreLogger

    public init(directory: URL, logger: CoreLogger = NoopLogger()) {
        url = directory.appendingPathComponent(Self.fileName)
        self.logger = logger
    }

    private struct State: Codable { var entries: [PendingUnpair] }

    private func load() -> [PendingUnpair] {
        JSONFile.read(State.self, url, logger: logger)?.entries ?? []
    }

    private func save(_ entries: [PendingUnpair]) throws {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try JSONFile.write(State(entries: entries), url)
        }
    }

    public func all() -> [PendingUnpair] {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        return load()
    }

    /// 断开时先调这个，成功落盘后才清配对。
    public func enqueue(_ entry: PendingUnpair) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        var entries = load().filter { $0.daemonNodeId != entry.daemonNodeId }
        entries.append(entry)
        try save(entries)
    }

    /// 重新配对同一台电脑：删掉它的条目。
    public func remove(daemonNodeId: String) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        let kept = load().filter { $0.daemonNodeId != daemonNodeId }
        try save(kept)
    }

    /// 只删「发出去的那一条」：飞行期间同一台电脑若又入队了新条目，不能被误删。
    fileprivate func remove(exactly entry: PendingUnpair) throws {
        JSONFile.lock.lock(); defer { JSONFile.lock.unlock() }
        try save(load().filter { $0 != entry })
    }
}

/// 把待撤销条目逐条重试一次。三个触发点（回前台 / 网络恢复 / 启动）都调 [flush]。
public final class PendingUnpairFlusher: @unchecked Sendable {
    public static let expiryMs: Int64 = 7 * 24 * 60 * 60 * 1000
    public static let timeoutMs: UInt64 = 5_000

    private let store: PendingUnpairStore
    private let now: @Sendable () -> Int64
    private let logger: CoreLogger
    private let transportFor: @Sendable (_ peerToken: String) -> CtrlTransport
    private let lock = NSLock()
    private var running = false

    public init(store: PendingUnpairStore, now: @escaping @Sendable () -> Int64, logger: CoreLogger = NoopLogger(),
                transportFor: @escaping @Sendable (_ peerToken: String) -> CtrlTransport) {
        self.store = store
        self.now = now
        self.logger = logger
        self.transportFor = transportFor
    }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func end() {
        lock.lock(); running = false; lock.unlock()
    }

    /// 一轮：先丢过期的，再对剩余每条各试一次。上一轮还在飞就直接跳过（触发点会叠在一起）。
    public func flush() async {
        guard begin() else { return }
        defer { end() }
        for entry in store.all() {
            if now() - entry.createdAtMs >= Self.expiryMs {
                try? store.remove(exactly: entry)
                logger.log("unpair-outbox: expired desktop=\(LogRedact.id(entry.daemonNodeId)) ageDays>=7, dropped")
                continue
            }
            await attempt(entry)
        }
    }

    /// 发一次；该删的删。返回条目是否已了结（成功或被拒）。
    @discardableResult
    public func attempt(_ entry: PendingUnpair) async -> Bool {
        let tag = "desktop=\(LogRedact.id(entry.daemonNodeId))"
        let params = entry.pairingEpoch.isEmpty ? [String: String]() : ["pairing_epoch": entry.pairingEpoch]
        do {
            let resp = try await ProtoClient(transport: transportFor(entry.peerToken))
                .callRaw(Methods.deviceUnpair, params, timeoutMs: Self.timeoutMs)
            if resp.ok {
                try? store.remove(exactly: entry)
                logger.log("unpair-outbox: delivered \(tag), removed")
                return true
            }
            if resp.error?.code == Codes.notAuthorized {
                try? store.remove(exactly: entry)
                logger.log("unpair-outbox: \(tag) no longer knows this phone (NOT_AUTHORIZED), treated as done, removed")
                return true
            }
            logger.log("unpair-outbox: \(tag) rejected code=\(resp.error?.code ?? "?") msg_key=\(resp.error?.msgKey ?? "?"), kept")
        } catch {
            logger.log("unpair-outbox: \(tag) unreachable (\(type(of: error))), kept")
        }
        return false
    }
}
