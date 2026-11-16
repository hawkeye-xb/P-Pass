// #1731 本地授权目录来源：目录媒体源（ADR §2 FolderMediaSource / §3 身份与内容版本 / §4 每轮发现与去重）。
// 在根目录授权内递归枚举元数据（不读完整文件、不负责传输），生成 MediaSnapshot / MediaDetails。
// 游标契约（ADR）：changes 恒空、currentPosition 返回 folder-v1 占位、libraryIdentity nil、preciseDiscovery false；
// 新素材只在 reconcile 轮被 inScope 对账发现。
import AVFoundation
import Foundation
import ImageIO
import PPassCore
import UniformTypeIdentifiers

/// nil = 独立装配的测试/诊断源不做范围过滤；产品装配必须提供实际存值，未保存时返回空范围。
typealias FolderScopeProvider = @Sendable () -> (selected: Set<String>, known: Set<String>, since: BackupSince)?

final class FolderMediaSource: MediaSource, FolderSourceIdentifying, @unchecked Sendable {
    /// 装配路由用：本来源的 sourceId（folder:<sourceId>:<opaque> 的第二段）。
    let folderSourceId: String
    /// Folder 游标占位（仅满足协议；不表示扫描进度，不用于重置判断）。
    static let positionPlaceholder = "folder-v1"
    /// 已授权但尚未随范围保存；重启或后台心跳都不能把它当成已选来源。
    static let pendingScopeStatus = "pendingScope"

    private let registry: FolderRegistry
    private let sourceId: String
    private let directory: URL
    private let logger: CoreLogger
    private let scopeProvider: FolderScopeProvider

    init(registry: FolderRegistry, sourceId: String, directory: URL, logger: CoreLogger, scope: FolderScopeProvider? = nil) {
        self.registry = registry
        self.sourceId = sourceId
        self.folderSourceId = sourceId
        self.directory = directory
        self.logger = logger
        self.scopeProvider = scope ?? { nil }
    }

    // MARK: 枚举（根授权内）

    private struct ScannedFile {
        let relativePath: String
        let modifiedAtMs: Int64?
        let capturedAtMs: Int64?
        let sizeBytes: Int64?
    }

    /// 递归枚举根目录里的图片 / 视频文件元数据。完整成功返回 (路径集合, 缺席 opaqueId)；中途失败抛错（本轮「不知道」）。
    private func enumerate(root: FolderRoot) async throws -> (files: [ScannedFile], missing: Set<String>) {
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
            // 首版统一跳过 symlink / alias（不解析、不跟随、不计失败）。alias 文件头是 bookmark 数据（"book\\0\\0\\0mark"），
            // 判字节签名（isAliasFileKey 在 iOS 不可用、FileAttributeType 无 typeAlias）。
            if values?.isSymbolicLink == true { continue }
            if let head = try? FileHandle(forReadingFrom: url) {
                defer { try? head.close() }
                let magic = try? head.read(upToCount: 8)
                if magic?.count == 8, String(decoding: magic!, as: UTF8.self).hasPrefix("book") { continue }
            }
            guard values?.isRegularFile == true else { continue }
            let uti = UTType(filenameExtension: url.pathExtension)
            guard let uti, uti.conforms(to: .image) || uti.conforms(to: .movie) || uti.conforms(to: .video) else { continue }
            let relative = url.path.dropFirst(root.url.path.count + 1)
            let path = try FolderPaths.normalize(String(relative))
            let modifiedMs = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            let size = values?.fileSize.map(Int64.init) ?? values?.totalFileAllocatedSize.map(Int64.init)
            let capturedMs = await Self.capturedAtMs(url: url, uti: uti)
            scanned.append(ScannedFile(relativePath: path, modifiedAtMs: modifiedMs,
                                       capturedAtMs: Self.effectiveCapturedAtMs(capturedAtMs: capturedMs, modifiedAtMs: modifiedMs), sizeBytes: size))
        }
        // 中途失败：本轮报错（不是完整枚举），缺席不能判源缺失。
        guard !failed else { throw FolderSourceError(reason: "enumeration failed mid-way") }
        scanned.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        // 只有完整枚举成功才对账映射（缺席 = 源缺失）。
        let missing = try registry.reconcile(sourceId: sourceId, observedPaths: scanned.map(\.relativePath))
        return (scanned, missing)
    }

    /// 一次完整枚举（每轮发现都全量对账，ADR §4）。失败桥接成 PPassCore SourceUnavailable（授权失效）或原样上抛其它错误。
    private func scan() async throws -> (paths: [String], missing: Set<String>, versions: [String: String], captures: [String: Int64]) {
        guard let record = registry.record(id: sourceId) else {
            throw SourceUnavailable(reason: "folder source \(sourceId) not registered")
        }
        let root: FolderRoot
        do {
            root = try FolderBookmarks.resolve(record, registry: registry, logger: logger)
        } catch let e as FolderSourceError {
            logger.log("folder \(sourceId): source unavailable (\(e.reason))")
            throw SourceUnavailable(reason: e.reason)
        }
        return try await FolderBookmarks.withScope(root.url) { _ in
            let scanned: [ScannedFile]
            let missing: Set<String>
            do {
                (scanned, missing) = try await self.enumerate(root: root)
            } catch let e as FolderSourceError {
                throw SourceUnavailable(reason: e.reason)
            }
            var versions: [String: String] = [:]
            var captures: [String: Int64] = [:]
            for file in scanned {
                let opaque = self.registry.opaqueId(sourceId: self.sourceId, relativePath: file.relativePath)
                // 元数据取不全按不可得处理：version 置空串，调用方按「疑似变化」重读（不能伪装成未变化）。
                versions[opaque] = FolderMediaSource.sourceVersion(modifiedAtMs: file.modifiedAtMs, sizeBytes: file.sizeBytes)
                if let captured = file.capturedAtMs { captures[opaque] = captured }
            }
            let paths = scanned.map(\.relativePath)
            self.logger.log("folder \(sourceId): scan ok items=\(paths.count) missing=\(missing.count)")
            return (paths, missing, versions, captures)
        }
    }

    /// sourceVersion = `modifiedAtMs:size`；任一取不到就给空串（按不可得处理，下轮当疑似变化重读）。
    static func sourceVersion(modifiedAtMs: Int64?, sizeBytes: Int64?) -> String {
        guard let modifiedAtMs, let sizeBytes, modifiedAtMs > 0, sizeBytes >= 0 else { return "" }
        return "\(modifiedAtMs):\(sizeBytes)"
    }

    func mediaId(opaqueId: String) -> String { "folder:\(sourceId):\(opaqueId)" }

    /// 范围检查必须先于枚举：取消勾选的目录不应被读取，也不应因授权失效拖住其他来源。
    private func isSourceSelected(_ sourceBucket: String) -> Bool {
        guard let scope = scopeProvider() else { return true }
        if scope.selected.contains(sourceBucket) {
            // 范围已成功保存后才解除待保存状态；在此之前不扫描、不备份。
            if var record = registry.record(id: sourceId), record.status == Self.pendingScopeStatus {
                record.status = "registered"
                _ = registry.upsert(record)
            }
            return true
        }
        if registry.record(id: sourceId)?.status == Self.pendingScopeStatus { return false }
        return ScopePolicy.initialFolderSelection(saved: scope.selected, known: scope.known, available: [sourceBucket]).contains(sourceBucket)
    }

    // MARK: MediaSource

    /// 对账扫描：文件夹与相册共用选中来源和时间档，id 按字节序大于 after，严格升序分页。
    /// 必须先按 **mediaId 字节序**排序再取 prefix（引擎按 id 严格升序推进游标；路径顺序与随机 opaqueId 无关，
    /// 按路径分页会把「id ≤ 游标但排在后面」的文件永久跳过——PhotoMediaSource 同一先例）。
    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        let sourceBucket = Self.bucketId(sourceId: sourceId)
        guard isSourceSelected(sourceBucket) else { return [] }
        let scan = try await self.scan()
        let all: [(id: String, opaque: String)] = scan.paths.map {
            let opaque = registry.opaqueId(sourceId: sourceId, relativePath: $0)
            return (mediaId(opaqueId: opaque), opaque)
        }.sorted { MediaOrder.precedes($0.id, $1.id) }
        var out: [MediaSnapshot] = []
        for entry in all {
            if let after, !MediaOrder.precedes(after, entry.id) { continue }
            let captured = scan.captures[entry.opaque]
            if let scope = scopeProvider(), !ScopeKey.inTime(capturedAtMs: captured, since: scope.since) { continue }
            let bucket = ScopeKey.encode(albums: [sourceBucket], capturedAtMs: captured)
            out.append(MediaSnapshot(mediaId: entry.id, sourceVersion: scan.versions[entry.opaque] ?? "", bucketId: bucket))
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
            root = try FolderBookmarks.resolve(record, registry: registry, logger: logger)
        } catch let e as FolderSourceError {
            throw SourceUnavailable(reason: e.reason)
        }
        return try await FolderBookmarks.withScope(root.url) { _ in
            // 根不可达 = 授权失效口径（抛 SourceUnavailable）；根在、文件不在 = nil（源缺失）。
            var rootIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.url.path, isDirectory: &rootIsDir), rootIsDir.boolValue else {
                throw SourceUnavailable(reason: "root not accessible")
            }
            let url = root.url.appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil as MediaDetails? }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedMs = values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            let size = values?.fileSize.map(Int64.init)
            let uti = UTType(filenameExtension: url.pathExtension)
            let mime = uti?.preferredMIMEType ?? "application/octet-stream"
            let capturedMs = await Self.capturedAtMs(url: url, uti: uti)
            let effective = Self.effectiveCapturedAtMs(capturedAtMs: capturedMs, modifiedAtMs: modifiedMs)
            let bucket = ScopeKey.encode(albums: [Self.bucketId(sourceId: sourceId)], capturedAtMs: effective)
            return MediaDetails(
                snapshot: MediaSnapshot(mediaId: mediaId, sourceVersion: Self.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: size), bucketId: bucket),
                fileName: (path as NSString).lastPathComponent, mimeType: mime, sizeBytes: size ?? 0, captureAtMs: effective ?? 0)
        }
    }

    /// 哪些此刻还在目录里。nil = 读不出来（枚举失败 = 不知道，调用方不许当「全都没了」）。
    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        let sourceBucket = Self.bucketId(sourceId: sourceId)
        guard isSourceSelected(sourceBucket) else {
            // 已取消的来源不参与本轮缺席判定，不能因根不可达阻塞其他来源，也不能误报源缺失。
            return Set(mediaIds)
        }
        guard let record = registry.record(id: sourceId) else { return nil }
        let root: FolderRoot
        do {
            root = try FolderBookmarks.resolve(record, registry: registry, logger: logger)
        } catch let e as FolderSourceError {
            logger.log("folder \(sourceId): presence unknown (\(e.reason))")
            return nil
        }
        do {
            return try await FolderBookmarks.withScope(root.url) { _ in
                let (files, _): ([ScannedFile], Set<String>) = try await self.enumerate(root: root)
                let presentOpaque = Set(files.map { self.registry.opaqueId(sourceId: self.sourceId, relativePath: $0.relativePath) })
                return Set(mediaIds.filter { id in
                    guard let opaque = Self.opaqueId(of: id, sourceId: self.sourceId) else { return false }
                    return presentOpaque.contains(opaque)
                })
            }
        } catch {
            // 枚举失败 = 不知道（ADR：不得把不可用来源当空集）。
            self.logger.log("folder \(self.sourceId): presence unknown (\(error.localizedDescription))")
            return nil
        }
    }

    /// G 不可信到「G 以下不会漏照片」：每轮对账都扫（协议默认就是 false，这里显式声明语义）。
    var preciseDiscovery: Bool { false }

    /// 范围时间与内容版本分开：只有拍摄/创建元数据缺失时才回退修改时间；sourceVersion 始终仍用修改时间。
    static func effectiveCapturedAtMs(capturedAtMs: Int64?, modifiedAtMs: Int64?) -> Int64? {
        capturedAtMs ?? modifiedAtMs
    }

    /// 使用系统媒体框架读取元数据，不按文件名或 Blackmagic 路径猜时间。
    private static func capturedAtMs(url: URL, uti: UTType?) async -> Int64? {
        if uti?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let ms = imageCapturedAtMs(properties: properties) {
            return ms
        }
        if uti?.conforms(to: .movie) == true || uti?.conforms(to: .video) == true,
           let item = try? await AVAsset(url: url).load(.creationDate),
           let date = item.dateValue {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    /// ImageIO 的 EXIF/TIFF 时间。OffsetTimeOriginal 与 DateTimeOriginal 必须配套；没有偏移时按本机时区解释墙钟。
    static func imageCapturedAtMs(properties: [String: Any], calendar: Calendar = .current) -> Int64? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let candidates: [(Any?, Any?)] = [
            (exif?[kCGImagePropertyExifDateTimeOriginal as String], exif?["OffsetTimeOriginal"]),
            (exif?[kCGImagePropertyExifDateTimeDigitized as String], exif?["OffsetTimeDigitized"]),
            (tiff?[kCGImagePropertyTIFFDateTime as String], tiff?["OffsetTime"]),
        ]
        for (raw, offset) in candidates {
            guard let text = raw as? String else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = exifTimeZone(offset as? String) ?? calendar.timeZone
            if let date = formatter.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        return nil
    }

    private static func exifTimeZone(_ raw: String?) -> TimeZone? {
        guard let raw, raw.count == 6, raw.first == "+" || raw.first == "-" else { return nil }
        let parts = raw.dropFirst().split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), hour <= 23, minute < 60 else { return nil }
        let seconds = (hour * 3600 + minute * 60) * (raw.first == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

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
