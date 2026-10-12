import Foundation

/// 一次发现的结果。对位 ARCH-01 的「新照片按 G 取；G 只服务新照片，只在新照片提交时推进」。
public enum Discovery: Equatable {
    /// 还没有 G：从此刻起步（对位 Android 在 G 缺失时从 `maxGeneration` 起步）。此刻以前的照片不归发现管，
    /// 由对账扫描（范围内全量，按内容哈希判重）负责。
    case start(at: ChangeToken)
    /// 正常增量。
    case changes(ChangeWindow)
    /// token 失效（3105）、明细缺失（3210）或 token 解不出，增量这条路走不通，改走全量重扫：
    /// 1. **先**把 G 设成 `restartAt`。它是在读历史失败**之后**、重扫**之前**取的，重扫期间新增的照片下一轮会作为增量出现；
    /// 2. 对范围内全部照片走对账扫描。已经备份过的照片字节没变、内容哈希也没变，桌面判重回「已有」，不会重传。
    ///    收敛靠内容哈希，不靠计数。
    case rescan(reason: ChangeHistoryError, restartAt: ChangeToken)
}

extension ChangeHistoryError {
    /// 只有这三种走全量重扫，其余错误（如授权被收回）原样上抛。
    public var requiresRescan: Bool {
        switch self {
        case .tokenExpired, .detailsUnavailable, .undecodableToken: return true
        case .other: return false
        }
    }
}

/// 从 G 开始的一段变更。
public struct ChangeWindow: Equatable {
    /// 本窗口的起点，也就是当前的 G。
    public let from: ChangeToken
    public let records: [ChangeRecord]

    public init(from: ChangeToken, records: [ChangeRecord]) {
        self.from = from
        self.records = records
    }

    /// 窗口内的新照片：按插入顺序排列并去重，去掉窗口内插入后又被删的。
    /// 只看 inserted。新照片入库后系统做分析会再产生 updated 事件，那不是新照片。
    public var newAssetIds: [String] {
        var deletedLater = Set<String>()
        var seen = Set<String>()
        var out: [String] = []
        for record in records.reversed() {
            deletedLater.formUnion(record.deletedAssetIds)
            for id in record.insertedAssetIds.reversed() where !deletedLater.contains(id) && seen.insert(id).inserted {
                out.append(id)
            }
        }
        return out.reversed()
    }

    /// 窗口内被删掉的照片（在窗口内新插入的不算）。仅作信息，不影响 G。
    public var deletedAssetIds: Set<String> {
        let inserted = Set(records.flatMap(\.insertedAssetIds))
        return Set(records.flatMap(\.deletedAssetIds)).subtracting(inserted)
    }

    /// 窗口末尾的 token（窗口为空时就是 ``from``）。
    public var endToken: ChangeToken { records.last?.token ?? from }

    /// G 可以推进到哪里：最远的那条变更，要求它及之前插入的新照片**都已了结**（`isSettled` 为真）。
    ///
    /// 了结的含义由调用方定：已提交，或者不在范围内、在跳过名单里，按 ARCH-01 都算。
    /// 窗口内插入后又被删的照片自动算了结。只有删除或更新的变更不会挡住 G。
    ///
    /// 返回值一定是 ``from``，或者 ``records`` 里某一条的 token。G 只会沿着系统给的变更序列往后走，结构上不可能倒退。
    public func advance(isSettled: (String) -> Bool) -> ChangeToken {
        let alive = Set(newAssetIds)
        var reached = from
        for record in records {
            for id in record.insertedAssetIds where alive.contains(id) && !isSettled(id) {
                return reached
            }
            reached = record.token
        }
        return reached
    }
}

/// 把变更历史读成 ``Discovery``。
public struct ChangeDiscovery {
    private let history: ChangeHistoryReading

    public init(history: ChangeHistoryReading) {
        self.history = history
    }

    /// - Parameter g: 已提交的 G；nil 表示从未建立。
    public func discover(since g: ChangeToken?) throws -> Discovery {
        guard let g else { return .start(at: try history.currentToken()) }
        do {
            return .changes(ChangeWindow(from: g, records: try history.changes(since: g)))
        } catch let error as ChangeHistoryError where error.requiresRescan {
            return .rescan(reason: error, restartAt: try history.currentToken())
        }
    }
}

/// G 落盘。一个文件，原子替换（对位 Android `WatermarkStore`）。
///
/// 目录由调用方给出（IOS-12 定在 App Group 容器里）。文件里存的是归档后的原始字节。文件损坏时 ``load()`` 照样把字节读出来，
/// 解不出 token 会在 ``ChangeDiscovery`` 里变成 `.rescan(.undecodableToken)`，不会悄悄当成「没有 G」从此刻起步而漏掉照片。
public struct ChangeTokenStore {
    public let fileURL: URL

    public init(directory: URL, name: String = "photos.change-token") {
        self.fileURL = directory.appendingPathComponent(name)
    }

    public func load() throws -> ChangeToken? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return ChangeToken(archived: try Data(contentsOf: fileURL))
    }

    public func save(_ token: ChangeToken) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try token.archived.write(to: fileURL, options: .atomic)
    }
}
