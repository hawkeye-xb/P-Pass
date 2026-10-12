// 系统自带 libsqlite3 的最薄封装（不引第三方依赖）。只够 OrderStore 用：预编译语句、绑定、逐行读、事务。
import Foundation
import SQLite3

/// SQLite 报错。[code] 是 sqlite3 的主错误码（`SQLITE_CORRUPT` / `SQLITE_NOTADB` 等）。
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite(\(code)): \(message)" }

    /// 文件本身坏了（不是某条 SQL 写错）：对位 Android 默认 `DatabaseErrorHandler` 的删库重建条件。
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc & 0xFF, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc & 0xFF, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    /// 执行一条写语句，返回受影响行数。
    @discardableResult
    func run(_ sql: String, _ args: [SQLiteValue] = []) throws -> Int {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    /// 查询：逐行交给 [row]。
    func query(_ sql: String, _ args: [SQLiteValue] = [], _ row: (SQLiteRow) throws -> Void) throws {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw error(rc) }
            try row(SQLiteRow(statement: st))
        }
    }

    func lastInsertRowId() -> Int64 { sqlite3_last_insert_rowid(handle) }

    private func prepare(_ sql: String, _ args: [SQLiteValue]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &st, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch arg {
            case .null: brc = sqlite3_bind_null(st, idx)
            case let .int(v): brc = sqlite3_bind_int64(st, idx, v)
            case let .text(v): brc = sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case let .blob(v):
                brc = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR) }
            }
            guard brc == SQLITE_OK else {
                sqlite3_finalize(st)
                throw error(brc)
            }
        }
        return st
    }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case text(String)
    case blob(Data)

    static func optText(_ s: String?) -> SQLiteValue { s.map(SQLiteValue.text) ?? .null }
    static func bool(_ b: Bool) -> SQLiteValue { .int(b ? 1 : 0) }
}

struct SQLiteRow {
    let statement: OpaquePointer?

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    func blob(_ i: Int32) -> Data? {
        guard !isNull(i), let p = sqlite3_column_blob(statement, i) else { return isNull(i) ? nil : Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(statement, i)))
    }
}
