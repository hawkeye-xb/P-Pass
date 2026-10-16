import Foundation
import SQLite3

/// 收件箱的集成测试夹具：每个测试一个独立的临时库文件。
enum InboxIT {
    static func dbPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-it-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backup-orders.db").path
    }

    /// 直接往 `inbox_meta` 写一个令牌（模拟存坏的字节 / 另一个图库的旧令牌）。表由 `Inbox.init` 建好。
    static func plantToken(_ bytes: Data, at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "InboxIT", code: 1) }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO inbox_meta (key, value) VALUES ('inbox_token', ?)", -1, &st, nil) == SQLITE_OK else {
            throw NSError(domain: "InboxIT", code: 2)
        }
        defer { sqlite3_finalize(st) }
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(st, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw NSError(domain: "InboxIT", code: 3) }
    }
}

/// 收集收件箱日志（线程安全）。
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
