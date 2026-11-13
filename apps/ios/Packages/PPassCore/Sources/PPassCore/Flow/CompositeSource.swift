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
}

/// 把多个 MediaSource 合成对引擎的一个 MediaSource（ADR §1/§2）。
/// - inScope / changes：顺序扫描各来源并合并，按 mediaId 字节序稳定排序、全局分页。
/// - presence 合并（ADR）：任一来源不可信（nil）或读不出 → 整体 nil，**不得返回部分并集**。
/// - 任一来源抛 SourceUnavailable → 原样上抛（整条 Flow 等待是 ADR 明确的首版代价）。
/// - libraryIdentity / currentPosition：PhotoKit 是唯一的「库」语义来源；目录来源占位且 nil，不参与。
public final class CompositeMediaSource: MediaSource, @unchecked Sendable {
    /// PhotoKit 来源（唯一的库身份与游标持有者）。
    private let library: MediaSource
    /// 其余来源（首版最多一个 FolderMediaSource；按数组顺序扫描）。
    private let others: [MediaSource]

    public init(library: MediaSource, others: [MediaSource] = []) {
        self.library = library
        self.others = others
    }

    /// 按前缀路由到对应来源（folder: → others 里的目录来源；其余 → library）。
    private func route(_ mediaId: String) -> MediaSource? {
        if MediaSourceRouting.isFolder(mediaId) {
            return others.first
        }
        return library
    }

    public func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        var merged: [MediaSnapshot] = []
        // 每个来源各自拉一页，合并后按 mediaId 字节序排序取 prefix（引擎按 id 严格升序推进游标）。
        for source in [library] + others {
            merged += try await source.inScope(after: after, limit: limit)
        }
        return Array(merged.sorted { MediaOrder.precedes($0.mediaId, $1.mediaId) }.prefix(limit))
    }

    /// 合并各来源的增量；目录来源恒空批（ADR），不破坏位置单调性。
    public func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        var merged: [MediaSnapshot] = try await library.changes(after: position, limit: limit)
        for source in others {
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
        // 按前缀分组，每组路由到对应来源。
        // 路由只按前缀分两组：folder → others.first，其余 → library（与 lookup 同一规则）。
        var folderIds: [String] = []
        var libraryIds: [String] = []
        for id in mediaIds {
            if MediaSourceRouting.isFolder(id) { folderIds.append(id) } else { libraryIds.append(id) }
        }
        var present: Set<String> = []
        if let source = others.first, !folderIds.isEmpty {
            guard let ids = try await source.existingIds(folderIds) else { return nil }
            present.formUnion(ids)
        }
        if !libraryIds.isEmpty {
            guard let ids = try await library.existingIds(libraryIds) else { return nil }
            present.formUnion(ids)
        }
        return present
    }

    /// 全部来源都精确才算精确（协议默认 false，目录来源显式 false）。
    public var preciseDiscovery: Bool {
        ([library] + others).allSatisfy { $0.preciseDiscovery }
    }
}

/// 把多个 MediaImporter 合成一个（ADR §2）：import 按前缀分发，**release 广播给全部子导入器**（各自幂等清理）——
/// 不按 contentHash 推断来源（哈希判断不了来源），也不改变导入结果。手选（picked）只可能来自 PhotoKit 路径。
public final class CompositeImporter: MediaImporter, @unchecked Sendable {
    private let library: MediaImporter
    private let others: [MediaImporter]

    public init(library: MediaImporter, others: [MediaImporter] = []) {
        self.library = library
        self.others = others
    }

    public func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
        if MediaSourceRouting.isFolder(details.snapshot.mediaId) {
            guard let folder = others.first else {
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
        for importer in others {
            importer.release(contentHash)
        }
    }
}

/// Composite 装配里没有目录来源却收到 folder: 的 id——装配错误，直接暴露。
public struct FolderMediaMissing: Error {
    public init() {}
}

