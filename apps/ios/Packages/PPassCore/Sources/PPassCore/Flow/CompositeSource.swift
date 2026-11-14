// #1731 本地授权目录来源：组合（ADR §1 固定主流程 / §2 模块职责 / §4 presence 合并）。
// CompositeMediaSource / CompositeImporter 只是把多个来源装进现有的 MediaSource / MediaImporter 接口——
// 不是新的流程阶段，不返回部分可信结果；FlowEngine 仍每次处理一件，不并行跑两条备份链路。
import Foundation

/// 多来源的 mediaId 分发：`folder:` 前缀 = 目录来源（FolderImporter/FolderMediaSource），其余 = PhotoKit。
/// 分发规则与装配一一对应，两个类共用。
public enum MediaSourceRouting {
    public static func isFolder(_ mediaId: String) -> Bool {
        mediaId.hasPrefix("folder:")
    }

    /// `folder:<sourceId>:<opaqueItemId>` 的第二段（sourceId）；非 folder id 或段数不对返回 nil。
    public static func sourceId(of mediaId: String) -> String? {
        guard isFolder(mediaId) else { return nil }
        let body = String(mediaId.dropFirst("folder:".count))
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[0])
    }
}

/// FolderMediaSource 自报 sourceId（PPassCore 不知道 app 层类型；装配时向下转型取一次）。
public protocol FolderSourceIdentifying: MediaSource {
    var folderSourceId: String { get }
}

/// 把多个 MediaSource 合成对引擎的一个 MediaSource（ADR §1/§2）。
/// - inScope / changes：顺序扫描各来源并合并，按 mediaId 字节序稳定排序、全局分页。
/// - presence 合并（ADR）：任一来源不可信（nil）或读不出 → 整体 nil，**不得返回部分并集**。
/// - 任一来源抛 SourceUnavailable → 原样上抛（整条 Flow 等待是 ADR 明确的首版代价）。
/// - libraryIdentity / currentPosition：PhotoKit 是唯一的「库」语义来源；目录来源占位且 nil，不参与。
public final class CompositeMediaSource: MediaSource, @unchecked Sendable {
    /// PhotoKit 来源（唯一的库身份与游标持有者）。
    private let library: MediaSource
    /// 其余来源（FolderMediaSource；按 mediaId 里的 sourceId 精确路由）。
    /// 锁保护：设置页运行时替换（#1763）。读取取快照，替换不中断在飞的扫描。
    private var others: [MediaSource]
    /// sourceId → 来源（folder:<sourceId>:<opaque> 的第二段；FolderMediaSource 的 id 已核实唯一）。
    private var bySourceId: [String: MediaSource]
    private let setLock = NSLock()

    public init(library: MediaSource, others: [MediaSource] = []) {
        self.library = library
        self.others = []
        self.bySourceId = [:]
        replaceFolderSources(others)
    }

    /// 运行时替换目录来源集合（#1763 设置页添加 / 移除 / 重新授权后；引擎持有 media 为 let，这是
    /// 新目录进引擎、被移除目录退出引擎的唯一出口）。锁内整体替换：已发起的扫描拿替换前的快照继续。
    /// 集合里仍按 FolderSourceIdentifying 自报的 sourceId 建路由（与 init 同一规则）。
    public func replaceFolderSources(_ sources: [MediaSource]) {
        setLock.lock(); defer { setLock.unlock() }
        others = sources
        var map: [String: MediaSource] = [:]
        for source in sources {
            if let folder = source as? FolderSourceIdentifying {
                map[folder.folderSourceId] = source
            }
        }
        bySourceId = map
    }

    /// 当前目录集合快照（替换与读取互斥；快照后再替换不影响这次遍历）。
    private func folderSnapshot() -> (sources: [MediaSource], byId: [String: MediaSource]) {
        setLock.lock(); defer { setLock.unlock() }
        return (others, bySourceId)
    }

    /// 按 mediaId 路由：folder:<sourceId>:<opaque> → 对应 sourceId 的目录来源（没有则 nil，装配与 id 不一致直接暴露）；
    /// 其余 → library。
    private func route(_ mediaId: String) -> MediaSource? {
        if MediaSourceRouting.isFolder(mediaId) {
            let (_, byId) = folderSnapshot()
            return MediaSourceRouting.sourceId(of: mediaId).flatMap { byId[$0] }
        }
        return library
    }

    public func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        var merged: [MediaSnapshot] = []
        // 每个来源各自拉一页，合并后按 mediaId 字节序排序取 prefix（引擎按 id 严格升序推进游标）。
        for source in [library] + folderSnapshot().sources {
            merged += try await source.inScope(after: after, limit: limit)
        }
        return Array(merged.sorted { MediaOrder.precedes($0.mediaId, $1.mediaId) }.prefix(limit))
    }

    /// 合并各来源的增量；目录来源恒空批（ADR），不破坏位置单调性。
    public func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        var merged: [MediaSnapshot] = try await library.changes(after: position, limit: limit)
        for source in folderSnapshot().sources {
            merged += try await source.changes(after: position, limit: limit)
        }
        return merged
    }

    /// PhotoKit 的游标（目录来源的占位不参与；首版 library 恒在装配里）。
    public func currentPosition() async throws -> DiscoveryPosition {
        try await library.currentPosition()
    }

    /// 聚合身份：只有 PhotoKit 有库语义；目录来源 nil 不触发重置（ADR）。
    public func libraryIdentity() async throws -> String? {
        try await library.libraryIdentity()
    }

    /// 按前缀路由 lookup；路由不到的 id 返回 nil（不是这个来源的）。
    public func lookup(_ mediaId: String) async throws -> MediaDetails? {
        guard let source = route(mediaId) else { return nil }
        return try await source.lookup(mediaId)
    }

    /// presence 合并（ADR）：任一来源不可信（nil）→ 整体 nil；不得返回部分并集、不得把不可用来源当空集。
    public func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        // 按 mediaId 里的 sourceId 分组，每组路由到对应来源（与 lookup / import 同一规则，不只 others.first）；
        // 非 folder → library。sourceId 在装配里没有的 folder id（来源已移除或 id 不成形）：本组合不认领，视作缺席——
        // 与 lookup 路由不到返回 nil 同一口径，不会让一个已移除的来源把对账永久卡在「不知道」。
        var libraryIds: [String] = []
        var folderBySource: [String: [String]] = [:]
        for id in mediaIds {
            if MediaSourceRouting.isFolder(id) {
                folderBySource[MediaSourceRouting.sourceId(of: id) ?? "", default: []].append(id)
            } else {
                libraryIds.append(id)
            }
        }
        var present: Set<String> = []
        if !libraryIds.isEmpty {
            guard let ids = try await library.existingIds(libraryIds) else { return nil }
            present.formUnion(ids)
        }
        for (sourceId, ids) in folderBySource {
            guard sourceId != "", let source = folderSnapshot().byId[sourceId] else { continue } // 装配里没有 → 缺席
            guard let r = try await source.existingIds(ids) else { return nil }
            present.formUnion(r)
        }
        return present
    }

    /// 全部来源都精确才算精确（协议默认 false，目录来源显式 false）。
    public var preciseDiscovery: Bool {
        ([library] + folderSnapshot().sources).allSatisfy { $0.preciseDiscovery }
    }
}

/// 把多个 MediaImporter 合成一个（ADR §2）：import 按前缀分发，**release 广播给全部子导入器**（各自幂等清理）——
/// 不按 contentHash 推断来源（哈希判断不了来源），也不改变导入结果。手选（picked）只可能来自 PhotoKit 路径。
public final class CompositeImporter: MediaImporter, @unchecked Sendable {
    private let library: MediaImporter
    /// 锁保护：设置页运行时替换（#1763）。读取取快照，替换不中断在飞的导入。
    private var others: [MediaImporter]
    /// sourceId → 目录导入器（folder:<sourceId>:<opaque> 按第二段精确分发）。
    private var bySourceId: [String: MediaImporter]
    private let setLock = NSLock()

    public init(library: MediaImporter, others: [MediaImporter] = []) {
        self.library = library
        self.others = []
        self.bySourceId = [:]
        replaceFolderSources(others)
    }

    /// 运行时替换目录导入器集合（#1763，与 CompositeMediaSource.replaceFolderSources 同一口径：
    /// 设置页添加 / 移除 / 重新授权后，导入侧按新集合分发）。在飞的导入拿替换前的快照继续；
    /// 已移除来源的引用与授权由其导入器自身的出口清理（FolderImporter.releaseHeld / deinit，ADR §5），
    /// 由装配方在退役时调用，不经这里的替换负责。
    public func replaceFolderSources(_ importers: [MediaImporter]) {
        setLock.lock(); defer { setLock.unlock() }
        others = importers
        var map: [String: MediaImporter] = [:]
        for importer in importers {
            if let folder = importer as? FolderImportIdentifying {
                map[folder.folderSourceId] = importer
            }
        }
        bySourceId = map
    }

    /// 当前目录导入器集合快照。
    private func folderSnapshot() -> (importers: [MediaImporter], byId: [String: MediaImporter]) {
        setLock.lock(); defer { setLock.unlock() }
        return (others, bySourceId)
    }

    public func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
        if MediaSourceRouting.isFolder(details.snapshot.mediaId) {
            guard let sourceId = MediaSourceRouting.sourceId(of: details.snapshot.mediaId),
                  let folder = folderSnapshot().byId[sourceId] else {
                throw FolderMediaMissing()
            }
            return try await folder.importMedia(details, onFetch: onFetch)
        }
        return try await library.importMedia(details, onFetch: onFetch)
    }

    /// 手选只可能来自 PhotoKit 路径（目录来源不支持 picked，ADR）。
    public func importPicked(_ item: PickedItem) async throws -> ImportResult {
        try await library.importPicked(item)
    }

    /// 广播给全部子导入器（各自幂等）：不做来源推断。
    public func release(_ contentHash: String) {
        library.release(contentHash)
        for importer in folderSnapshot().importers {
            importer.release(contentHash)
        }
    }
}

/// Composite 装配里没有对应目录来源却收到 folder: 的 id——装配错误，直接暴露。
public struct FolderMediaMissing: Error {
    public init() {}
}

/// FolderImporter 自报 sourceId（与 FolderSourceIdentifying 同理；PPassCore 不知道 app 层类型）。
public protocol FolderImportIdentifying: MediaImporter {
    var folderSourceId: String { get }
}

