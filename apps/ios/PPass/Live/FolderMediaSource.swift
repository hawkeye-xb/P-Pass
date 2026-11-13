// #1731 本地授权目录来源：目录媒体源（ADR §2 FolderMediaSource / §3 身份与内容版本 / §4 每轮发现与去重）。
// 在根目录授权内递归枚举元数据（不读完整文件、不负责传输），生成 MediaSnapshot / MediaDetails。
// 游标契约（ADR）：changes 恒空、currentPosition 返回 folder-v1 占位、libraryIdentity nil、preciseDiscovery false；
// 新素材只在 reconcile 轮被 inScope 对账发现。
import Foundation
import PPassCore
import UniformTypeIdentifiers

final class FolderMediaSource: MediaSource, @unchecked Sendable {
    /// Folder 游标占位（仅满足协议；不表示扫描进度，不用于重置判断）。
    static let positionPlaceholder = "folder-v1"

    private let registry: FolderRegistry
    private let sourceId: String
    private let directory: URL
    private let logger: CoreLogger

    init(registry: FolderRegistry, sourceId: String, directory: URL, logger: CoreLogger) {
        self.registry = registry
        self.sourceId = sourceId
        self.directory = directory
        self.logger = logger
    }

    // MARK: 枚举（根授权内）

    private struct ScannedFile {
        let relativePath: String
        let modifiedAtMs: Int64?
        let sizeBytes: Int64?
    }

    /// 递归枚举根目录里的图片 / 视频文件元数据。完整成功返回 (路径集合, 缺席 opaqueId)；中途失败抛错（本轮「不知道」）。
    private func enumerate(root: FolderRoot) throws -> (paths: [String], missing: Set<String>) {
        var scanned: [ScannedFile] = []
        var failed = false
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root.url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [], errorHandler: { url, error in
                self.logger.log("folder \(self.sourceId): enumeration failed at \(LogRedact.id(url.lastPathComponent)): \(error.localizedDescription)")
                failed = true
                return false
            }) else {
            throw FolderSourceError(reason: "enumeration failed")
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey])
            // 首版统一跳过 symlink / alias（不解析、不跟随、不计失败）。
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            let uti = UTType(filenameExtension: url.pathExtension)
            guard let uti, uti.conforms(to: .image) || uti.conforms(to: .movie) || uti.conforms(to: .video) else { continue }
            let relative = url.path.dropFirst(root.url.path.count + 1)
            let path = try FolderPaths.normalize(String(relative))
            let modifiedMs = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            let size = values?.fileSize.map(Int64.init) ?? values?.totalFileAllocatedSize.map(Int64.init)
            scanned.append(ScannedFile(relativePath: path, modifiedAtMs: modifiedMs, sizeBytes: size))
        }
        // 中途失败：本轮报错（不是完整枚举），缺席不能判源缺失。
        guard !failed else { throw FolderSourceError(reason: "enumeration failed mid-way") }
        let paths = scanned.map(\.relativePath).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        // 只有完整枚举成功才对账映射（缺席 = 源缺失）。
        let missing = registry.reconcile(sourceId: sourceId, observedPaths: paths)
        return (paths, missing)
    }

    /// 一次完整枚举（每轮发现都全量对账，ADR §4）。失败桥接成 PPassCore SourceUnavailable（授权失效）或原样上抛其它错误。
    private func scan() async throws -> (paths: [String], missing: Set<String>, versions: [String: String]) {
        guard let record = registry.record(id: sourceId) else {
            throw SourceUnavailable(reason: "folder source \(sourceId) not registered")
        }
        let root: FolderRoot
        do {
            root = try FolderBookmarks.resolve(record, directory: directory, logger: logger)
        } catch let e as FolderSourceError {
            logger.log("folder \(sourceId): source unavailable (\(e.reason))")
            throw SourceUnavailable(reason: e.reason)
        }
        return try await FolderBookmarks.withScope(root.url) { _ in
            let (paths, missing) = try self.enumerate(root: root)
            var versions: [String: String] = [:]
            for path in paths {
                let opaque = self.registry.opaqueId(sourceId: self.sourceId, relativePath: path)
                let url = root.url.appendingPathComponent(path)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modifiedMs = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
                let size = values?.fileSize.map(Int64.init)
                // 元数据取不全按不可得处理：version 置空串，调用方按「疑似变化」重读（不能伪装成未变化）。
                versions[opaque] = FolderMediaSource.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: size)
            }
            self.logger.log("folder \(sourceId): scan ok items=\(paths.count) missing=\(missing.count)")
            return (paths, missing, versions)
        }
    }

    /// sourceVersion = `modifiedAtMs:size`；任一取不到就给空串（按不可得处理，下轮当疑似变化重读）。
    static func sourceVersion(modifiedAtMs: Int64?, sizeBytes: Int64?) -> String {
        guard let modifiedAtMs, let sizeBytes, modifiedAtMs > 0, sizeBytes >= 0 else { return "" }
        return "\(modifiedAtMs):\(sizeBytes)"
    }

    func mediaId(opaqueId: String) -> String { "folder:\(sourceId):\(opaqueId)" }

    // MARK: MediaSource

    /// 对账扫描：范围内（目录来源 = 全部图片/视频）、id 按字节序大于 after 的照片，严格升序分页。
    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        let scan = try await self.scan()
        var out: [MediaSnapshot] = []
        for path in scan.paths {
            let opaque = registry.opaqueId(sourceId: sourceId, relativePath: path)
            let id = mediaId(opaqueId: opaque)
            if let after, !MediaOrder.precedes(after, id) { continue }
            out.append(MediaSnapshot(mediaId: id, sourceVersion: scan.versions[opaque] ?? "", bucketId: Self.bucketId(sourceId: sourceId)))
            if out.count >= limit { break }
        }
        return out
    }

    /// ADR：目录新项不依赖 incremental changes——恒返回空批。
    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] { [] }

    /// 稳定占位，仅满足协议；不表示扫描进度。
    func currentPosition() async throws -> DiscoveryPosition { DiscoveryPosition(raw: Data(Self.positionPlaceholder.utf8)) }

    /// nil = 说不出来，不因占位位置触发重置。
    func libraryIdentity() async throws -> String? { nil }

    /// 这张照片现在的样子；没有则 nil。
    func lookup(_ mediaId: String) async throws -> MediaDetails? {
        guard let opaque = Self.opaqueId(of: mediaId, sourceId: sourceId) else { return nil }
        guard let path = registry.relativePath(sourceId: sourceId, opaqueId: opaque) else { return nil }
        guard let record = registry.record(id: sourceId) else { throw SourceUnavailable(reason: "folder source not registered") }
        let root: FolderRoot
        do {
            root = try FolderBookmarks.resolve(record, directory: directory, logger: logger)
        } catch let e as FolderSourceError {
            throw SourceUnavailable(reason: e.reason)
        }
        let url = root.url.appendingPathComponent(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedMs = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let size = values?.fileSize.map(Int64.init)
        let uti = UTType(filenameExtension: url.pathExtension)
        let mime = uti?.preferredMIMEType ?? "application/octet-stream"
        let captureAtMs = modifiedMs ?? 0
        return MediaDetails(
            snapshot: MediaSnapshot(mediaId: mediaId, sourceVersion: Self.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: size), bucketId: Self.bucketId(sourceId: sourceId)),
            fileName: (path as NSString).lastPathComponent, mimeType: mime, sizeBytes: size ?? 0, captureAtMs: captureAtMs)
    }

    /// 哪些此刻还在目录里。nil = 读不出来（枚举失败 = 不知道，调用方不许当「全都没了」）。
    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        guard let record = registry.record(id: sourceId) else { return nil }
        let root: FolderRoot
        do {
            root = try FolderBookmarks.resolve(record, directory: directory, logger: logger)
        } catch let e as FolderSourceError {
            logger.log("folder \(sourceId): presence unknown (\(e.reason))")
            return nil
        }
        return try await FolderBookmarks.withScope(root.url) { _ in
            let (paths, _) = try self.enumerate(root: root)
            let presentOpaque = Set(paths.map { self.registry.opaqueId(sourceId: self.sourceId, relativePath: $0) })
            return Set(mediaIds.filter { id in
                guard let opaque = Self.opaqueId(of: id, sourceId: self.sourceId) else { return false }
                return presentOpaque.contains(opaque)
            })
        }
    }

    /// G 不可信到「G 以下不会漏照片」：每轮对账都扫（协议默认就是 false，这里显式声明语义）。
    var preciseDiscovery: Bool { false }

    // MARK: 组装

    static func bucketId(sourceId: String) -> String { "folder:\(sourceId)" }

    /// 从 mediaId 里取 opaqueId（前缀必须匹配本来源）；不匹配返回 nil。
    static func opaqueId(of mediaId: String, sourceId: String) -> String? {
        let prefix = "folder:\(sourceId):"
        let bytes = Array(mediaId.utf8)
        let prefixBytes = Array(prefix.utf8)
        guard bytes.count > prefixBytes.count, Array(bytes.prefix(prefixBytes.count)) == prefixBytes else { return nil }
        return String(decoding: bytes.dropFirst(prefixBytes.count), as: UTF8.self)
    }
}
