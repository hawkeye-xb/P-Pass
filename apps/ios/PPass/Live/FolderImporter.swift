// #1731 本地授权目录来源：目录导入器（ADR §2 FolderImporter / §5 授权生命周期与读取）。
// 按私有映射找到文件，在协调回调内打开句柄（用 newURL），经 provider import_media(path:fd:) 引用导入。
// 引用没成立（预期 inline 之外的回退）按单张失败处理，不静默复制回退；scope 配对 start/stop；
// 导入成功后为 provider 供数期保住根授权，release 时放掉（ADR：持有期覆盖 provider 实际需要）。
import Foundation
import PPassCore
import PPassTransport

final class FolderImporter: MediaImporter, FolderImportIdentifying, @unchecked Sendable {
    /// 装配路由用：本来源的 sourceId。
    let folderSourceId: String
    private let registry: FolderRegistry
    private let sourceId: String
    private let directory: URL
    private let provider: NativeProvider
    private let logger: CoreLogger
    private let coordinator = NSFileCoordinator()
    /// hash → 供数期授权令牌（provider 按引用在 serve 时还要读源文件）。release 时关掉。
    private var heldScopes: [String: FolderScopeLease] = [:]
    private let heldLock = NSLock()

    init(registry: FolderRegistry, sourceId: String, directory: URL, provider: NativeProvider, logger: CoreLogger) {
        self.registry = registry
        self.sourceId = sourceId
        self.folderSourceId = sourceId
        self.directory = directory
        self.provider = provider
        self.logger = logger
    }

    func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
        let mediaId = details.snapshot.mediaId
        guard let opaque = FolderMediaSource.opaqueId(of: mediaId, sourceId: sourceId) else {
            throw FolderImportError(reason: "mediaId not a folder id of source \(sourceId)")
        }
        guard let path = registry.relativePath(sourceId: sourceId, opaqueId: opaque) else {
            // 映射里没有了：按源缺失处理（照片库里列着、原图读不到的同一口径）。
            return .sourceMissing
        }
        guard let record = registry.record(id: sourceId) else {
            throw SourceUnavailable(reason: "folder source \(sourceId) not registered")
        }
        let root: FolderRoot
        do {
            root = try FolderBookmarks.resolve(record, registry: registry, logger: logger)
        } catch let e as FolderSourceError {
            throw SourceUnavailable(reason: e.reason)
        }
        let target = root.url.appendingPathComponent(path)
        // 每次文件打开都在各自的协调回调内完成，使用回调提供的 newURL；security scope 由根负责（不在子文件上重复开）。
        let imported: (hash: String, size: UInt64, byReference: Bool, fallback: String?) = try await FolderBookmarks.withScope(root.url) { _ in
            var lastError: Error?
            for _ in 0..<2 {
                do {
                    // 协调回调（同步）里只打开文件句柄；fd 在句柄关闭前有效，FFI 先 dup（#1126 契约）。
                    var handle: FileHandle?
                    var usedURL: URL?
                    var coordError: NSError?
                    self.coordinator.coordinate(readingItemAt: target, options: [], error: &coordError) { newURL in
                        usedURL = newURL
                        handle = try? FileHandle(forReadingFrom: newURL)
                    }
                    if let coordError { throw FolderImportError(reason: "coordination failed: \(coordError.localizedDescription)") }
                    guard let handle, let usedURL else { throw FolderImportError(reason: "open failed after coordination") }
                    defer { try? handle.close() }
                    let r = try await self.provider.run { try $0.importMedia(path: usedURL.path, fd: handle.fileDescriptor) }
                    // ADR：不静默复制回退。provider 的 fallback 语义：
                    //   small（≤16KiB inline）/ already_in_store = store 的预期形态，接受；
                    //   identity_mismatch / head_mismatch / reference_failed / changed_during_import /
                    //   no_path = 引用没成立且不是预期的 inline，按单张失败（不静默复制）。
                    // 错误只带 fallback 枚举词，不带 r.detail（Rust 的 detail 里有绝对路径，不能进日志）。
                    let acceptedFallbacks: Set<String> = ["small", "already_in_store"]
                    if !r.byReference, let fallback = r.fallback, !acceptedFallbacks.contains(fallback) {
                        throw FolderImportError(reason: "reference import failed: \(fallback)")
                    }
                    return (r.hash, r.size, r.byReference, r.fallback)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as SourceUnavailable {
                    throw e
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    lastError = error
                    self.logger.log("folder \(self.sourceId): coordinated import failed (\(error.localizedDescription)); retrying once")
                }
            }
            throw lastError ?? FolderImportError(reason: "import failed")
        }
        // provider 按引用在 serve（桌面拉取）时还要读源文件：把根授权留到 release（供数期覆盖 provider 实际需要）。
        // 同 hash 已有令牌就沿用（引用指向同一内容，一个 scope 足够）。测试用的临时目录 start=false，令牌同样成对。
        heldLock.lock()
        if heldScopes[imported.hash] == nil {
            heldScopes[imported.hash] = FolderScopeLease(root.url)
        }
        heldLock.unlock()
        let refState = imported.byReference ? (imported.fallback.map { " ref=fallback:\($0)" } ?? " ref=yes") : ""
        AppLog.log("folder \(sourceId): imported bytes=\(imported.size) hash=\(imported.hash.prefix(16))\(refState)")
        return .imported(contentHash: imported.hash, sizeBytes: Int64(imported.size))
    }

    func importPicked(_ item: PickedItem) async throws -> ImportResult {
        throw PickedImportUnsupported()
    }

    /// 这份内容不再需要：幂等、不许抛。放掉 provider 的引用 hold 与供数期根授权。
    func release(_ contentHash: String) {
        try? provider.ffi.release(hash: contentHash)
        heldLock.lock()
        let lease = heldScopes.removeValue(forKey: contentHash)
        heldLock.unlock()
        if let lease { lease.close() }
    }
}

/// 一次 `startAccessingSecurityScopedResource` 的配对令牌（构造时 start、close/deinit 时 stop）。
/// start 返回 false（无 security scope，比如测试的普通目录）也保持成对，不重复 stop。
final class FolderScopeLease: @unchecked Sendable {
    private let started: Bool
    private let url: URL
    private let lock = NSLock()
    private var closed = false

    init(_ url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if started { url.stopAccessingSecurityScopedResource() }
    }

    deinit { close() }
}

struct FolderImportError: Error {
    let reason: String
}
