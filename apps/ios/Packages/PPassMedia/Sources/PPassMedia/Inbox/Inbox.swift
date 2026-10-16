import Foundation
import SQLite3

/// 收件箱里的一行：这张照片进箱时分到的序号，以及它的 localIdentifier。
public struct InboxEntry: Equatable, Sendable {
    public let seq: Int64
    public let assetId: String

    public init(seq: Int64, assetId: String) {
        self.seq = seq
        self.assetId = assetId
    }
}

/// 收件箱（iOS「取新系统」，refs #958）：给每张新照片一个只增不减、可以断点续取的位置。
///
/// Android 的系统媒体库给每张照片一个 `(GENERATION_MODIFIED, _id)`，引擎可以「取一张、推进一格」。PhotoKit 只按**变更**给令牌，
/// 一次变更可能新增多张，所以由这里补上：系统变更只用来往收件箱**追加**照片 id，SQLite `AUTOINCREMENT` 分配序号，
/// 引擎把序号当作发现游标 G（`discovery_state.position` 存 ``position(of:)`` 的编码）。
///
/// 定位：只服务「发现」这条快速通道，**不是事实来源**——只是一份「这些 id 按这个顺序出现过」的提示，取到的每一张都要再查相册现状。
/// 最终完整由对账保证。收件箱不认识账本、电脑、对账和引擎；它也**不推进任何东西**，推进 G 只有引擎。
///
/// 存储：和账本同一个 SQLite 文件（路径由 App 层注入），独立的表（`inbox` / `inbox_meta`）和独立的连接；
/// 不碰 `user_version`（账本用它判断是否删表重建）。连接要在账本打开之后再开：账本发现文件损坏会删掉整个文件。
///
/// 线程：内部一把锁串行化。引擎在 await 处可重入（计数与取件可能同时调 `changes`），进箱不能并发，否则同一条变更会进两次。
public final class Inbox: @unchecked Sendable {
    private let history: ChangeHistoryReading
    private let log: (String) -> Void
    private let lock = NSLock()
    private var db: OpaquePointer?

    /// 测试钩子：每提交完一条变更的事务之后调用；抛错模拟「进箱途中被杀」。
    var afterChangeCommitted: (() throws -> Void)?

    private static let tokenKey = "inbox_token"

    public init(path: String, history: ChangeHistoryReading, log: @escaping (String) -> Void = { _ in }) throws {
        self.history = history
        self.log = log
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw InboxStorageError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        try exec("""
            CREATE TABLE IF NOT EXISTS inbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS inbox_meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            """)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: 对外

    /// G 重置（首次建立、换电脑、照片库换了）时由媒体源的 `currentPosition()` 调用。
    ///
    /// - 还没有令牌：设为 PhotoKit 当前令牌（首次初始化；此前的照片走 SCOPE_ADDED 对账，不进箱）。
    /// - 返回当前最大序号（AUTOINCREMENT 的高水位，空表也不回退；从未进箱为 0）。
    /// - 删掉 `seq <= 返回值` 的行：G 将被设成这个值，这些行此后不会再被取到（交给对账）。这是收件箱唯一删行的地方。
    public func currentPosition() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if try token() == nil { try saveToken(history.currentToken()) }
        let top = try highWater()
        try run("DELETE FROM inbox WHERE seq <= ?", [.int(top)])
        return top
    }

    /// 取件：`seq > after`，按 seq 升序，最多 `limit` 条。G 之后不够 `limit` 条时先进箱（§3.2）。**不删任何行**：
    /// `after` 不一定是 G（引擎计数翻页时会传 G 之后的位置）。
    public func entries(after: Int64, limit: Int) throws -> [InboxEntry] {
        lock.lock(); defer { lock.unlock() }
        let pending = try read(after: after, limit: limit)
        if pending.count >= limit { return pending }
        try ingest()
        return try read(after: after, limit: limit)
    }

    /// G 的编码：seq 的 8 字节大端。
    public static func position(of seq: Int64) -> Data {
        withUnsafeBytes(of: seq.bigEndian) { Data($0) }
    }

    /// G 的解码。解不出（长度不对，例如旧格式）按 0 处理：G 之后的全部行都会被取一遍，引擎按已有 order 判重。
    public static func seq(fromPosition raw: Data) -> Int64 {
        guard raw.count == 8 else { return 0 }
        return raw.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }

    // MARK: 进箱

    /// 用令牌读变更历史；**每处理完一条变更提交一个事务**：按 id 排序追加这条变更新增的 id，同时把令牌更新为这条变更的令牌。
    /// 读到一半被杀，下次从已提交的令牌继续，不重复、不漏。进箱不看备份范围。
    ///
    /// 令牌失效（3105 / 3210 / 解不出）：不抛错、不动 G——只把自己的令牌重置为当前令牌，打一行日志。
    /// 已进箱的行照常往下取；缺口里没进箱的照片由对账兜底（iOS `preciseDiscovery = false`，每个对账轮都置脏扫描）。
    /// 其他错误（例如授权被收回）原样上抛，令牌不动。
    private func ingest() throws {
        guard let since = try token() else {
            try saveToken(history.currentToken())
            log("inbox: no change token yet; starting from the current one")
            return
        }
        let records: [ChangeRecord]
        do {
            records = try history.changes(since: since)
        } catch let error as ChangeHistoryError where error.invalidatesToken {
            try saveToken(history.currentToken())
            log("inbox: change token expired; reset to current, gap left to reconcile (\(error))")
            return
        }
        for record in records {
            var seen = Set<String>()
            let ids = record.insertedAssetIds.sorted().filter { seen.insert($0).inserted }
            try transaction {
                for id in ids { try run("INSERT INTO inbox (asset_id) VALUES (?)", [.text(id)]) }
                try writeToken(record.token)
            }
            try afterChangeCommitted?()
        }
    }

    // MARK: 存储

    private func read(after: Int64, limit: Int) throws -> [InboxEntry] {
        var out: [InboxEntry] = []
        try query("SELECT seq, asset_id FROM inbox WHERE seq > ? ORDER BY seq LIMIT ?", [.int(after), .int(Int64(limit))]) {
            out.append(InboxEntry(seq: sqlite3_column_int64($0, 0), assetId: String(cString: sqlite3_column_text($0, 1))))
        }
        return out
    }

    /// AUTOINCREMENT 的高水位：删行之后也不回退。
    private func highWater() throws -> Int64 {
        var top: Int64 = 0
        try query("SELECT seq FROM sqlite_sequence WHERE name = 'inbox'", []) { top = sqlite3_column_int64($0, 0) }
        try query("SELECT COALESCE(MAX(seq), 0) FROM inbox", []) { top = max(top, sqlite3_column_int64($0, 0)) }
        return top
    }

    private func token() throws -> ChangeToken? {
        var out: ChangeToken?
        try query("SELECT value FROM inbox_meta WHERE key = ?", [.text(Self.tokenKey)]) { st in
            let n = Int(sqlite3_column_bytes(st, 0))
            out = ChangeToken(archived: sqlite3_column_blob(st, 0).map { Data(bytes: $0, count: n) } ?? Data())
        }
        return out
    }

    private func saveToken(_ token: ChangeToken) throws {
        try transaction { try writeToken(token) }
    }

    private func writeToken(_ token: ChangeToken) throws {
        try run("INSERT OR REPLACE INTO inbox_meta (key, value) VALUES (?, ?)", [.text(Self.tokenKey), .blob(token.archived)])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private enum Value {
        case int(Int64)
        case text(String)
        case blob(Data)
    }

    private func fail(_ rc: Int32) -> InboxStorageError {
        InboxStorageError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw fail(rc) }
    }

    private func run(_ sql: String, _ args: [Value]) throws {
        try query(sql, args) { _ in }
    }

    private func query(_ sql: String, _ args: [Value], _ row: (OpaquePointer?) throws -> Void) throws {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &st, nil)
        guard rc == SQLITE_OK else { throw fail(rc) }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch arg {
            case let .int(v): brc = sqlite3_bind_int64(st, idx, v)
            case let .text(v): brc = sqlite3_bind_text(st, idx, v, -1, transient)
            case let .blob(v): brc = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32($0.count), transient) }
            }
            guard brc == SQLITE_OK else { throw fail(brc) }
        }
        while true {
            let step = sqlite3_step(st)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw fail(step) }
            try row(st)
        }
    }
}

/// 收件箱的 SQLite 错误。
public struct InboxStorageError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "inbox SQLite(\(code)): \(message)" }
}
