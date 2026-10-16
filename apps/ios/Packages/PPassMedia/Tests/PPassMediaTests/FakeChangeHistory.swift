import Foundation
@testable import PPassMedia

/// 内存里的变更历史。token 用 "t0"、"t1"……的 UTF-8 字节表示。
final class FakeChangeHistory: ChangeHistoryReading {
    var records: [ChangeRecord] = []
    var current = FakeChangeHistory.token(0)
    /// 非 nil 时 `changes(since:)` 一直抛它，直到测试清掉。
    var failure: ChangeHistoryError?
    private(set) var calls: [String] = []

    static func token(_ n: Int) -> ChangeToken { ChangeToken(archived: Data("t\(n)".utf8)) }

    func currentToken() throws -> ChangeToken {
        calls.append("current")
        return current
    }

    func changes(since token: ChangeToken) throws -> [ChangeRecord] {
        calls.append("changes")
        if let failure { throw failure }
        guard let start = records.firstIndex(where: { $0.token == token }) else {
            return token == Self.token(0) ? records : []
        }
        return Array(records[(start + 1)...])
    }

    @discardableResult
    func append(inserted: [String] = [], updated: [String] = [], deleted: [String] = []) -> ChangeToken {
        let token = Self.token(records.count + 1)
        records.append(ChangeRecord(token: token, inserted: inserted, updated: updated, deleted: deleted))
        current = token
        return token
    }
}
