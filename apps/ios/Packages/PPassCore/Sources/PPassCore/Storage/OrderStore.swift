// order 存储 + 跳过名单 + 游标 + 审计 outbox（对位 Android `OrderStore` 接口与 `SqliteOrderStore`）。
// 所有写操作各自是一个事务：要么全部生效，要么一条都不生效。
import Foundation
import SQLite3

public protocol OrderStore: AnyObject, Sendable {
    /// 插入一行，返回完整行。[advance] / [scanTo] / [audit] 与插入同一事务。
    @discardableResult
    func insert(_ order: NewOrder, advance: DiscoveryPosition?, scanTo: String?, audit: AuditRecord?) throws -> Order
    func get(_ id: Int64) throws -> Order?
    /// 该 media_id 当前的那一行（id 最大）。
    func currentForMedia(_ mediaId: String) throws -> Order?
    /// 每个 media_id 当前的那一行，按 media_id 字节序升序（分页读，不一次读进内存）。
    func currentOrders() throws -> PagedSequence<Order>
    /// 当前行里状态属于 [states]、id > [afterId] 的，按 id 升序，最多 [limit] 条。
    func currentInStates(_ states: Set<OrderState>, afterId: Int64, limit: Int) throws -> [Order]
    /// 当前行里 CONFIRMED、有 hash、id > [afterId] 的，按 id 升序（分页问桌面用）。
    func confirmedWithHashAfter(_ afterId: Int64, limit: Int) throws -> [Order]
    /// 比较并转换：只有当前状态在 [expected] 里时才改成 [to]。没改时其余一条都不写。
    @discardableResult
    func transition(_ id: Int64, expected: Set<OrderState>, to: OrderState, countAttempt: Bool, contentHash: String?, advance: DiscoveryPosition?, scanTo: String?, audit: AuditRecord?) throws -> Bool
    /// 打 / 清 `source_missing`。只对 CONFIRMED 行、且值真的变了才算改；**不动 updated_at**。
    @discardableResult
    func setSourceMissing(_ id: Int64, missing: Bool, audit: AuditRecord?) throws -> Bool

    // 意图：跳过名单
    func isSkipped(_ mediaId: String) throws -> Bool
    func skipList() throws -> PagedSequence<String>
    func countSkipped(bucketIds: Set<String>?) throws -> Int64
    /// 「取消剩余 N 张」：一个事务把 [targets] 写进跳过名单，它们当前行里还没结局的改成 SKIPPED_BY_USER；
    /// 弹窗之后已有同版本结局的不动。任何一项失败整批回滚。
    func cancelRemaining(_ targets: [SkipTarget], audit: AuditRecord?) throws -> SkipResult
    /// 「恢复已跳过」：一个事务清空跳过名单并把扫描置脏。order 行不动。返回恢复了几张。
    func restoreSkipped(audit: AuditRecord?) throws -> Int

    // 游标
    func discoveryState() throws -> DiscoveryState?
    func saveDiscoveryState(_ state: DiscoveryState) throws
    /// 只推进 G（覆盖写；单调由引擎保证）。
    func advanceDiscovery(_ position: DiscoveryPosition) throws
    func scanState() throws -> ScanState
    func markScanDirty() throws
    /// `S = max(S, cursor)`（字节序）。
    func advanceScan(_ cursor: String) throws
    func finishScan() throws
    /// 用户点「重试」：当前行里所有 FAILED 改回 PENDING（失败次数保留）。
    func retryFailed(audit: AuditRecord?) throws -> Int

    // UI 读口径
    func countCurrentByState(bucketIds: Set<String>?) throws -> [OrderState: Int64]
    func countConfirmedPresent(bucketIds: Set<String>?) throws -> Int64
    func lastConfirmedAtMs() throws -> Int64
    func countSourceMissingSkipped(afterMs: Int64, upToMs: Int64) throws -> Int64

    // 审计
    func appendAudit(_ audit: AuditRecord) throws
    /// 同一个 [onceKey] 只追加一次（记没记过与审计同一事务）。
    @discardableResult
    func appendAuditOnce(_ onceKey: String, _ audit: AuditRecord) throws -> Bool
    func pendingAuditAfter(_ afterSeq: Int64, limit: Int) throws -> [SequencedAudit]
    func acknowledgeAudit(_ eventIds: Set<String>) throws
    func openRoundId() throws -> String?
    func openRound(_ roundId: String) throws
    /// 同一事务里补发终态并清掉未闭合标记（[audit] = nil 只清标记）。
    func closeRound(_ audit: AuditRecord?) throws

    /// 换桌面（#415 裁决 6）：[ownerKey] 与记着的不一样时清空 order、游标、审计 outbox，并把新 id 的起点抬到 [idFloor] 之上。
    /// **跳过名单保留**（用户意图，与哪台桌面无关）。返回是否清了。
    @discardableResult
    func claimOwner(_ ownerKey: String, idFloor: Int64) throws -> Bool
}

extension OrderStore {
    @discardableResult
    public func insert(_ order: NewOrder) throws -> Order { try insert(order, advance: nil, scanTo: nil, audit: nil) }

    @discardableResult
    public func transition(_ id: Int64, expected: Set<OrderState>, to: OrderState, countAttempt: Bool = false, contentHash: String? = nil) throws -> Bool {
        try transition(id, expected: expected, to: to, countAttempt: countAttempt, contentHash: contentHash, advance: nil, scanTo: nil, audit: nil)
    }

    public func currentInStates(_ states: Set<OrderState>) throws -> [Order] {
        try currentInStates(states, afterId: 0, limit: Int.max)
    }
}

/// 按页取数的惰性流：每页一次查询、查完即关语句，不挂着打开的游标；迭代期间写库也安全（键集分页只往前走）。
/// 不做成 `Sequence`：Swift 的 Sequence 不能抛错，读失败若被吞成「读完了」，差集会被静默算小。
public struct PagedSequence<Element> {
    let pageSize: Int
    let fetch: (_ after: Element?) throws -> [Element]

    public func cursor() -> PagedCursor<Element> { PagedCursor(self) }

    /// 读全部。
    public func collect() throws -> [Element] {
        var out: [Element] = []
        let c = cursor()
        while let e = try c.next() { out.append(e) }
        return out
    }
}

public final class PagedCursor<Element> {
    private let source: PagedSequence<Element>
    private var page: [Element] = []
    private var index = 0
    private var last: Element?
    private var exhausted = false

    init(_ source: PagedSequence<Element>) { self.source = source }

    public func next() throws -> Element? {
        if index >= page.count {
            if exhausted { return nil }
            page = try source.fetch(last)
            index = 0
            if page.count < source.pageSize { exhausted = true }
            if page.isEmpty { return nil }
        }
        let e = page[index]
        index += 1
        last = e
        return e
    }
}

/// [OrderStore] 的 SQLite 实现（系统 libsqlite3）。
///
/// 损坏处理对位 Android 默认 `DatabaseErrorHandler`：打开时发现文件不是数据库 / 已损坏 → **删库重建并记日志**。
/// 结局是空账本：已确认的照片在下一轮由扫描重新导入，桌面按 hash 回「已有」（O-03 / D-04），不重传字节。
public final class SQLiteOrderStore: OrderStore, @unchecked Sendable {
    public static let fileName = "backup-orders.db"
    static let pageSize = 256
    /// v1：iOS 首版 schema（字段与 Android v4 对齐，去掉 location_redacted；媒体 / 相册 id 为 TEXT；单库发现游标）。
    static let schemaVersion: Int64 = 1

    private let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    private let clock: @Sendable () -> Int64
    public let path: String
    /// 打开时是否因为损坏删库重建过（诊断页 / 测试读）。
    public let recoveredFromCorruption: Bool

    private static let ownerKey = "owner"
    private static let scanDirtyKey = "scan_dirty"
    private static let scanCursorKey = "scan_cursor"
    private static let openRoundKey = "open_round_id"
    private static let auditOncePrefix = "audit_once:"

    private static let columns = "id, media_id, source_version, bucket_id, content_hash, state, attempts, pairing_epoch, created_at_ms, updated_at_ms, source_missing"
    private static let isCurrent = "o.id = (SELECT MAX(id) FROM orders WHERE media_id = o.media_id)"
    private static let allStates = OrderState.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")

    private static let schema: [String] = [
        """
        CREATE TABLE orders (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            media_id        TEXT    NOT NULL,
            source_version  TEXT    NOT NULL,
            bucket_id       TEXT    NOT NULL,
            content_hash    TEXT,
            state           TEXT    NOT NULL CHECK (state IN (\(allStates))),
            attempts        INTEGER NOT NULL DEFAULT 0,
            pairing_epoch   TEXT    NOT NULL,
            created_at_ms   INTEGER NOT NULL,
            updated_at_ms   INTEGER NOT NULL,
            source_missing  INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX orders_media_id ON orders (media_id, id)",
        "CREATE INDEX orders_content_hash ON orders (content_hash)",
        "CREATE INDEX orders_state ON orders (state, id)",
        """
        CREATE TABLE discovery_state (
            singleton         INTEGER PRIMARY KEY CHECK (singleton = 1),
            position          BLOB    NOT NULL,
            library_identity  TEXT
        )
        """,
        """
        CREATE TABLE skip_list (
            media_id        TEXT    PRIMARY KEY,
            bucket_id       TEXT    NOT NULL,
            source_version  TEXT    NOT NULL,
            created_at_ms   INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE audit_outbox (
            seq            INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id       TEXT    NOT NULL UNIQUE,
            kind           TEXT    NOT NULL,
            round_id       TEXT,
            occurred_at_ms INTEGER NOT NULL,
            payload        TEXT    NOT NULL
        )
        """,
        "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    ]
    private static let tables = ["orders", "discovery_state", "skip_list", "audit_outbox", "meta"]

    /// 打开（不存在则建）。[directory] 是存储根。
    public convenience init(directory: URL, logger: CoreLogger = NoopLogger(), clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(path: directory.appendingPathComponent(Self.fileName).path, logger: logger, clock: clock)
    }

    public init(path: String, logger: CoreLogger = NoopLogger(), clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.path = path
        self.clock = clock
        do {
            db = try Self.openAndMigrate(path)
            recoveredFromCorruption = false
        } catch let error as SQLiteError where error.isCorruption {
            logger.log("order store: \(path) is corrupt (\(error)); deleting it and starting an empty ledger")
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
            db = try Self.openAndMigrate(path)
            recoveredFromCorruption = true
        }
    }

    private static func openAndMigrate(_ path: String) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: path)
        // 第一次真正读文件在这里：坏文件会在这一步报 NOTADB / CORRUPT。
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA foreign_keys=OFF")
        if version != schemaVersion {
            // 不认识的版本（含 0 = 新库）：删表重建。iOS 首版没有需要保留的旧数据。
            try db.exec("BEGIN IMMEDIATE")
            do {
                for t in tables { try db.exec("DROP TABLE IF EXISTS \(t)") }
                for sql in schema { try db.exec(sql) }
                try db.exec("PRAGMA user_version = \(schemaVersion)")
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
        return db
    }

    public func close() { db.close() }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    @discardableResult
    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try db.exec("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try db.exec("COMMIT")
                return result
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
    }

    private func readOrder(_ r: SQLiteRow) -> Order {
        Order(
            id: r.int(0), mediaId: r.text(1), sourceVersion: r.text(2), bucketId: r.text(3), contentHash: r.optText(4),
            state: OrderState(rawValue: r.text(5)) ?? .failed, attempts: Int(r.int(6)), pairingEpoch: r.text(7),
            createdAtMs: r.int(8), updatedAtMs: r.int(9), sourceMissing: r.int(10) != 0
        )
    }

    private func orders(_ sql: String, _ args: [SQLiteValue] = []) throws -> [Order] {
        try locked {
            var out: [Order] = []
            try db.query(sql, args) { out.append(readOrder($0)) }
            return out
        }
    }

    // MARK: 写入原语（只在事务里调用）

    private func metaGet(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    private func metaPut(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    private func metaDelete(_ key: String) throws {
        try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
    }

    private func readScan() throws -> ScanState {
        ScanState(dirty: try metaGet(Self.scanDirtyKey) == "1", cursor: try metaGet(Self.scanCursorKey))
    }

    private func writeScan(_ s: ScanState) throws {
        try metaPut(Self.scanDirtyKey, s.dirty ? "1" : "0")
        if let c = s.cursor { try metaPut(Self.scanCursorKey, c) } else { try metaDelete(Self.scanCursorKey) }
    }

    private func writeScanTo(_ cursor: String?) throws {
        guard let cursor else { return }
        let s = try readScan()
        if s.cursor == nil || MediaOrder.precedes(s.cursor!, cursor) { try writeScan(ScanState(dirty: s.dirty, cursor: cursor)) }
    }

    private func writeAdvance(_ p: DiscoveryPosition?) throws {
        guard let p else { return }
        // 有行就只改 position（不动 library_identity）；没有行就建一行。
        if try db.run("UPDATE discovery_state SET position = ? WHERE singleton = 1", [.blob(p.raw)]) == 0 {
            try db.run("INSERT INTO discovery_state (singleton, position, library_identity) VALUES (1, ?, NULL)", [.blob(p.raw)])
        }
    }

    private func writeAudit(_ a: AuditRecord?) throws {
        guard let a else { return }
        let payload = try String(decoding: JSONSerialization.data(withJSONObject: a.payload, options: [.sortedKeys]), as: UTF8.self)
        try db.run(
            "INSERT INTO audit_outbox (event_id, kind, round_id, occurred_at_ms, payload) VALUES (?, ?, ?, ?, ?)",
            [.text(a.eventId), .text(a.kind), .optText(a.roundId), .int(a.occurredAtMs), .text(payload)]
        )
    }

    // MARK: order

    /// 测试接缝（对位 Android InMemoryOrderStore.failNextInsert）：下一次 insert 在事务里抛这个错（例如存储满）。
    var failNextInsert: Error?

    @discardableResult
    public func insert(_ order: NewOrder, advance: DiscoveryPosition?, scanTo: String?, audit: AuditRecord?) throws -> Order {
        let id: Int64 = try inTransaction {
            if let injected = failNextInsert {
                failNextInsert = nil
                throw injected
            }
            let now = clock()
            try db.run(
                "INSERT INTO orders (media_id, source_version, bucket_id, content_hash, state, attempts, pairing_epoch, created_at_ms, updated_at_ms, source_missing) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, 0)",
                [.text(order.mediaId), .text(order.sourceVersion), .text(order.bucketId), .optText(order.contentHash), .text(order.state.rawValue), .text(order.pairingEpoch), .int(now), .int(now)]
            )
            let id = db.lastInsertRowId()
            try writeAdvance(advance)
            try writeScanTo(scanTo)
            try writeAudit(audit)
            return id
        }
        guard let row = try get(id) else { throw SQLiteError(code: SQLITE_INTERNAL, message: "inserted order \(id) not readable") }
        return row
    }

    public func get(_ id: Int64) throws -> Order? {
        try orders("SELECT \(Self.columns) FROM orders WHERE id = ?", [.int(id)]).first
    }

    public func currentForMedia(_ mediaId: String) throws -> Order? {
        try orders("SELECT \(Self.columns) FROM orders WHERE media_id = ? ORDER BY id DESC LIMIT 1", [.text(mediaId)]).first
    }

    public func currentOrders() throws -> PagedSequence<Order> {
        PagedSequence(pageSize: Self.pageSize) { [self] last in
            try orders(
                "SELECT \(Self.columns) FROM orders o WHERE o.media_id > ? AND \(Self.isCurrent) ORDER BY o.media_id ASC LIMIT \(Self.pageSize)",
                [.text(last?.mediaId ?? "")]
            )
        }
    }

    public func currentInStates(_ states: Set<OrderState>, afterId: Int64, limit: Int) throws -> [Order] {
        guard !states.isEmpty, limit > 0 else { return [] }
        let list = states.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
        let lim = limit == Int.max ? -1 : limit
        return try orders(
            "SELECT \(Self.columns) FROM orders o WHERE o.state IN (\(list)) AND o.id > ? AND \(Self.isCurrent) ORDER BY o.id ASC LIMIT \(lim)",
            [.int(afterId)]
        )
    }

    public func confirmedWithHashAfter(_ afterId: Int64, limit: Int) throws -> [Order] {
        try orders(
            "SELECT \(Self.columns) FROM orders o WHERE o.state = 'CONFIRMED' AND o.content_hash IS NOT NULL AND o.id > ? AND \(Self.isCurrent) ORDER BY o.id ASC LIMIT \(limit)",
            [.int(afterId)]
        )
    }

    @discardableResult
    public func transition(_ id: Int64, expected: Set<OrderState>, to: OrderState, countAttempt: Bool, contentHash: String?, advance: DiscoveryPosition?, scanTo: String?, audit: AuditRecord?) throws -> Bool {
        guard !expected.isEmpty else { return false }
        precondition(contentHash == nil || !contentHash!.isBlank, "contentHash must be nil or non-blank")
        var args: [SQLiteValue] = [.text(to.rawValue), .int(clock())]
        var sql = "UPDATE orders SET state = ?, updated_at_ms = ?"
        if countAttempt { sql += ", attempts = attempts + 1" }
        if let contentHash {
            sql += ", content_hash = IFNULL(content_hash, ?)"
            args.append(.text(contentHash))
        }
        sql += " WHERE id = ? AND state IN (\(expected.map { _ in "?" }.joined(separator: ",")))"
        args.append(.int(id))
        args += expected.map { .text($0.rawValue) }
        return try inTransaction {
            let changed = try db.run(sql, args) == 1
            if changed {
                try writeAdvance(advance)
                try writeScanTo(scanTo)
                try writeAudit(audit)
            }
            return changed
        }
    }

    @discardableResult
    public func setSourceMissing(_ id: Int64, missing: Bool, audit: AuditRecord?) throws -> Bool {
        try inTransaction {
            let flag: Int64 = missing ? 1 : 0
            let changed = try db.run(
                "UPDATE orders SET source_missing = ? WHERE id = ? AND state = 'CONFIRMED' AND source_missing != ?",
                [.int(flag), .int(id), .int(flag)]
            ) == 1
            if changed { try writeAudit(audit) }
            return changed
        }
    }

    // MARK: 跳过名单

    public func isSkipped(_ mediaId: String) throws -> Bool {
        try locked {
            var found = false
            try db.query("SELECT 1 FROM skip_list WHERE media_id = ?", [.text(mediaId)]) { _ in found = true }
            return found
        }
    }

    public func skipList() throws -> PagedSequence<String> {
        PagedSequence(pageSize: Self.pageSize) { [self] last in
            try locked {
                var out: [String] = []
                try db.query("SELECT media_id FROM skip_list WHERE media_id > ? ORDER BY media_id ASC LIMIT \(Self.pageSize)", [.text(last ?? "")]) { out.append($0.text(0)) }
                return out
            }
        }
    }

    private func bucketFilter(_ column: String, _ ids: Set<String>?) -> (String, [SQLiteValue]) {
        guard let ids else { return ("", []) }
        return (" AND \(column) IN (\(ids.map { _ in "?" }.joined(separator: ",")))", ids.sorted().map(SQLiteValue.text))
    }

    private func scalar(_ sql: String, _ args: [SQLiteValue]) throws -> Int64 {
        try locked {
            var v: Int64 = 0
            try db.query(sql, args) { v = $0.isNull(0) ? 0 : $0.int(0) }
            return v
        }
    }

    public func countSkipped(bucketIds: Set<String>?) throws -> Int64 {
        if let b = bucketIds, b.isEmpty { return 0 }
        let (f, a) = bucketFilter("bucket_id", bucketIds)
        return try scalar("SELECT COUNT(*) FROM skip_list WHERE 1\(f)", a)
    }

    public func cancelRemaining(_ targets: [SkipTarget], audit: AuditRecord?) throws -> SkipResult {
        try inTransaction {
            let now = clock()
            var written = 0, ordersSkipped = 0, untouched = 0
            for t in targets {
                guard !t.mediaId.isEmpty else { throw SQLiteError(code: SQLITE_CONSTRAINT, message: "mediaId must not be empty") }
                var current: (id: Int64, state: OrderState, version: String)?
                try db.query("SELECT id, state, source_version FROM orders WHERE media_id = ? ORDER BY id DESC LIMIT 1", [.text(t.mediaId)]) {
                    current = ($0.int(0), OrderState(rawValue: $0.text(1)) ?? .failed, $0.text(2))
                }
                if let c = current, c.state.isSettled, c.version == t.sourceVersion {
                    untouched += 1
                    continue
                }
                written += try db.run(
                    "INSERT OR IGNORE INTO skip_list (media_id, bucket_id, source_version, created_at_ms) VALUES (?, ?, ?, ?)",
                    [.text(t.mediaId), .text(t.bucketId), .text(t.sourceVersion), .int(now)]
                )
                if let c = current, c.state.isOpen {
                    try db.run("UPDATE orders SET state = 'SKIPPED_BY_USER', updated_at_ms = ? WHERE id = ?", [.int(now), .int(c.id)])
                    ordersSkipped += 1
                }
            }
            try writeAudit(audit)
            return SkipResult(written: written, ordersSkipped: ordersSkipped, untouched: untouched)
        }
    }

    public func restoreSkipped(audit: AuditRecord?) throws -> Int {
        try inTransaction {
            let removed = try db.run("DELETE FROM skip_list")
            try writeScan(ScanState(dirty: true, cursor: nil))
            try writeAudit(audit)
            return removed
        }
    }

    // MARK: 游标

    public func discoveryState() throws -> DiscoveryState? {
        try locked {
            var s: DiscoveryState?
            try db.query("SELECT position, library_identity FROM discovery_state WHERE singleton = 1") {
                s = DiscoveryState(position: DiscoveryPosition(raw: $0.blob(0) ?? Data()), libraryIdentity: $0.optText(1))
            }
            return s
        }
    }

    public func saveDiscoveryState(_ state: DiscoveryState) throws {
        try inTransaction {
            try db.run(
                "INSERT OR REPLACE INTO discovery_state (singleton, position, library_identity) VALUES (1, ?, ?)",
                [.blob(state.position.raw), .optText(state.libraryIdentity)]
            )
        }
    }

    public func advanceDiscovery(_ position: DiscoveryPosition) throws {
        try inTransaction { try writeAdvance(position) }
    }

    public func scanState() throws -> ScanState { try locked { try readScan() } }

    public func markScanDirty() throws { try inTransaction { try writeScan(ScanState(dirty: true, cursor: nil)) } }

    public func advanceScan(_ cursor: String) throws { try inTransaction { try writeScanTo(cursor) } }

    public func finishScan() throws { try inTransaction { try writeScan(ScanState(dirty: false, cursor: nil)) } }

    public func retryFailed(audit: AuditRecord?) throws -> Int {
        try inTransaction {
            let n = try db.run(
                "UPDATE orders SET state = 'PENDING', updated_at_ms = ? WHERE state = 'FAILED' AND id = (SELECT MAX(id) FROM orders o2 WHERE o2.media_id = orders.media_id)",
                [.int(clock())]
            )
            try writeAudit(audit)
            return n
        }
    }

    // MARK: UI 读口径

    public func countCurrentByState(bucketIds: Set<String>?) throws -> [OrderState: Int64] {
        if let b = bucketIds, b.isEmpty { return [:] }
        let (f, a) = bucketFilter("o.bucket_id", bucketIds)
        var out: [OrderState: Int64] = [:]
        try locked {
            try db.query("SELECT o.state, COUNT(*) FROM orders o WHERE \(Self.isCurrent)\(f) AND o.state != 'SKIPPED_BY_USER' GROUP BY o.state", a) {
                if let s = OrderState(rawValue: $0.text(0)) { out[s] = $0.int(1) }
            }
        }
        // 「已跳过」是意图：报跳过名单的张数，不是 order 行数。
        let skipped = try countSkipped(bucketIds: bucketIds)
        if skipped > 0 { out[.skippedByUser] = skipped }
        return out
    }

    public func countConfirmedPresent(bucketIds: Set<String>?) throws -> Int64 {
        if let b = bucketIds, b.isEmpty { return 0 }
        let (f, a) = bucketFilter("o.bucket_id", bucketIds)
        return try scalar("SELECT COUNT(*) FROM orders o WHERE o.state = 'CONFIRMED' AND o.source_missing = 0 AND \(Self.isCurrent)\(f)", a)
    }

    public func lastConfirmedAtMs() throws -> Int64 {
        try scalar("SELECT MAX(o.updated_at_ms) FROM orders o WHERE o.state = 'CONFIRMED' AND \(Self.isCurrent)", [])
    }

    public func countSourceMissingSkipped(afterMs: Int64, upToMs: Int64) throws -> Int64 {
        try scalar(
            "SELECT COUNT(*) FROM orders o WHERE o.state = 'SKIPPED_SOURCE_MISSING' AND o.updated_at_ms > ? AND o.updated_at_ms <= ? AND \(Self.isCurrent)",
            [.int(afterMs), .int(upToMs)]
        )
    }

    // MARK: 审计

    public func appendAudit(_ audit: AuditRecord) throws { try inTransaction { try writeAudit(audit) } }

    @discardableResult
    public func appendAuditOnce(_ onceKey: String, _ audit: AuditRecord) throws -> Bool {
        try inTransaction {
            let key = Self.auditOncePrefix + onceKey
            if try metaGet(key) != nil { return false }
            try metaPut(key, audit.eventId)
            try writeAudit(audit)
            return true
        }
    }

    public func pendingAuditAfter(_ afterSeq: Int64, limit: Int) throws -> [SequencedAudit] {
        try locked {
            var out: [SequencedAudit] = []
            try db.query("SELECT seq, event_id, kind, round_id, occurred_at_ms, payload FROM audit_outbox WHERE seq > ? ORDER BY seq ASC LIMIT \(limit)", [.int(afterSeq)]) {
                let payload = (try? JSONSerialization.jsonObject(with: Data($0.text(5).utf8))) as? [String: String] ?? [:]
                out.append(SequencedAudit(seq: $0.int(0), record: AuditRecord(eventId: $0.text(1), kind: $0.text(2), roundId: $0.optText(3), occurredAtMs: $0.int(4), payload: payload)))
            }
            return out
        }
    }

    public func acknowledgeAudit(_ eventIds: Set<String>) throws {
        guard !eventIds.isEmpty else { return }
        try inTransaction {
            for id in eventIds { try db.run("DELETE FROM audit_outbox WHERE event_id = ?", [.text(id)]) }
        }
    }

    public func openRoundId() throws -> String? { try locked { try metaGet(Self.openRoundKey) } }

    public func openRound(_ roundId: String) throws { try inTransaction { try metaPut(Self.openRoundKey, roundId) } }

    public func closeRound(_ audit: AuditRecord?) throws {
        try inTransaction {
            try writeAudit(audit)
            try metaDelete(Self.openRoundKey)
        }
    }

    // MARK: 换桌面

    @discardableResult
    public func claimOwner(_ ownerKey: String, idFloor: Int64) throws -> Bool {
        try inTransaction {
            let previous = try metaGet(Self.ownerKey)
            if previous == ownerKey { return false }
            let cleared = previous != nil
            if cleared {
                // 跳过名单保留：用户意图与哪台桌面无关（#413 裁定 9）。
                try db.run("DELETE FROM orders")
                try db.run("DELETE FROM discovery_state")
                try db.run("DELETE FROM audit_outbox")
                // 未闭合的那一轮属于旧桌面那套账（AUDIT-07），一起作废。
                try metaDelete(Self.openRoundKey)
                try writeScan(ScanState(dirty: true, cursor: nil))
            }
            // 桌面按 (node_id, pairing_epoch, queue_sequence) 记账：id 从 1 开始会撞上旧账本已完成的行。
            try db.run("DELETE FROM sqlite_sequence WHERE name = 'orders'")
            var maxId: Int64 = 0
            try db.query("SELECT IFNULL(MAX(id), 0) FROM orders") { maxId = $0.int(0) }
            try db.run("INSERT INTO sqlite_sequence (name, seq) VALUES ('orders', ?)", [.int(max(idFloor, maxId))])
            try metaPut(Self.ownerKey, ownerKey)
            return cleared
        }
    }
}

/// 配对成功后的账本归属（#935）：App 在每次配对成功时必须调用——账本是单表，靠「记着的桌面」判断要不要清。
/// 同一台桌面（daemonNodeId 相同）重新配对不动账本，已备份的不重传；换了一台则清空 order / 游标 / 审计 outbox
/// （跳过名单保留），新 id 起点抬到 [nowMs]（毫秒时间戳）之上。返回是否清了。
@discardableResult
public func adoptDesktop(_ store: OrderStore, daemonNodeId: String, nowMs: Int64) throws -> Bool {
    try store.claimOwner(daemonNodeId, idFloor: nowMs)
}
