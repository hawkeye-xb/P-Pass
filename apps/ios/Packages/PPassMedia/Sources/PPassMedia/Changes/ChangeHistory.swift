import Foundation
import Photos

/// 归档后的 `PHPersistentChangeToken`：收件箱（``Inbox``）读变更历史的位置，存在 `inbox_meta` 里。
///
/// 对外只当不透明字节用：可以持久化、可以比较是否相等，但**不能比较大小**（token 之间没有公开的序关系）。
/// 引擎的发现游标 G 不是它，而是收件箱的序号。
public struct ChangeToken: Equatable, Hashable, Codable, Sendable {
    public let archived: Data

    public init(archived: Data) {
        self.archived = archived
    }
}

/// 一次持久化变更：系统在一个事务里提交的照片插入、更新和删除，以及这次变更**之后**的 token。
public struct ChangeRecord: Equatable, Sendable {
    /// 游标推进到这里，就表示这次变更已经处理完。
    public let token: ChangeToken
    public let insertedAssetIds: [String]
    public let updatedAssetIds: [String]
    public let deletedAssetIds: [String]

    public init(token: ChangeToken, inserted: [String] = [], updated: [String] = [], deleted: [String] = []) {
        self.token = token
        self.insertedAssetIds = inserted
        self.updatedAssetIds = updated
        self.deletedAssetIds = deleted
    }
}

/// 读变更历史的错误。前三种表示令牌失效（处理方式相同，分开列出是为了日志里能看到具体原因），见 ``invalidatesToken``。
public enum ChangeHistoryError: Error, Equatable {
    /// 3105 `PHPhotosErrorPersistentChangeTokenExpired`：token 指向的库状态早于系统保留的变更历史。
    case tokenExpired
    /// 3210 `PHPhotosErrorPersistentChangeDetailsUnavailable`：某次变更的明细拿不到，无法从历史重建当前状态。
    case detailsUnavailable
    /// 存下来的字节解不出 token（盘上数据损坏，或系统改了归档格式）。
    case undecodableToken
    /// 其他错误（例如没有完整授权）。**不能**当作令牌失效：原样上抛，由调用方决定是等待还是报错。
    case other(code: Int, domain: String)
}

extension ChangeHistoryError {
    /// 令牌失效（3105 / 3210 / 解不出）：收件箱把令牌重置为当前令牌，缺口交给对账。其余错误原样上抛。
    public var invalidatesToken: Bool {
        switch self {
        case .tokenExpired, .detailsUnavailable, .undecodableToken: return true
        case .other: return false
        }
    }
}

/// 相册库的持久化变更历史。生产实现是 ``PhotoKitChangeHistory``，单测用 fake。
public protocol ChangeHistoryReading {
    /// 此刻相册库的 token。
    func currentToken() throws -> ChangeToken
    /// `token` 之后的全部变更，按时间先后排列。失败时抛 ``ChangeHistoryError``。
    func changes(since token: ChangeToken) throws -> [ChangeRecord]
}

/// ``ChangeHistoryReading`` 的 PhotoKit 实现（iOS 16+ `PHPersistentChangeToken`）。
public struct PhotoKitChangeHistory: ChangeHistoryReading {
    private let library: PHPhotoLibrary

    public init(library: PHPhotoLibrary = .shared()) {
        self.library = library
    }

    public func currentToken() throws -> ChangeToken {
        try Self.archive(library.currentChangeToken)
    }

    public func changes(since token: ChangeToken) throws -> [ChangeRecord] {
        let start = try Self.unarchive(token)
        let result: PHPersistentChangeFetchResult
        do {
            result = try library.fetchPersistentChanges(since: start)
        } catch {
            throw Self.classify(error)
        }
        // PHPersistentChangeFetchResult 在 Swift 里是 Sequence（ObjC 的 enumerateChangesWithBlock: 被 NS_REFINED_FOR_SWIFT 换掉了）。
        var records: [ChangeRecord] = []
        for change in result {
            let details: PHPersistentObjectChangeDetails
            do {
                details = try change.changeDetails(for: .asset)
            } catch {
                throw Self.classify(error)
            }
            records.append(ChangeRecord(
                token: try Self.archive(change.changeToken),
                inserted: details.insertedLocalIdentifiers.sorted(),
                updated: details.updatedLocalIdentifiers.sorted(),
                deleted: details.deletedLocalIdentifiers.sorted()
            ))
        }
        return records
    }

    static func archive(_ token: PHPersistentChangeToken) throws -> ChangeToken {
        ChangeToken(archived: try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true))
    }

    static func unarchive(_ token: ChangeToken) throws -> PHPersistentChangeToken {
        guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token.archived) else {
            throw ChangeHistoryError.undecodableToken
        }
        return decoded
    }

    static func classify(_ error: Error) -> ChangeHistoryError {
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain {
            switch ns.code {
            case PHPhotosError.persistentChangeTokenExpired.rawValue: return .tokenExpired
            case PHPhotosError.persistentChangeDetailsUnavailable.rawValue: return .detailsUnavailable
            default: break
            }
        }
        return .other(code: ns.code, domain: ns.domain)
    }
}
