// #1731 本地授权目录来源：目录导入器（ADR §2 FolderImporter / §5 授权生命周期与读取）。
// 按私有映射找到文件，在协调回调内读取（newURL），经 provider import_media(path:fd:) 引用导入（by_reference = true）。
// 引用导入失败按单张失败处理，不静默复制回退；每次 startAccessingSecurityScopedResource 成功都配对 stop。
import Foundation
import PPassCore
import PPassTransport

final class FolderImporter: MediaImporter, @unchecked Sendable {
    private let registry: FolderRegistry
    private let sourceId: String
    private let directory: URL
    private let provider: NativeProvider
    private let logger: CoreLogger
    private let coordinator = NSFileCoordinator()

    init(registry: FolderRegistry, sourceId: String, directory: URL, provider: NativeProvider, logger: CoreLogger) {
        self.registry = registry
        self.sourceId = sourceId
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
            root = try FolderBookmarks.resolve(record, directory: directory, logger: logger)
        } catch let e as FolderSourceError {
            throw SourceUnavailable(reason: e.reason)
        }
        let target = root.url.appendingPathComponent(path)
        // 每次文件打开都在各自的协调回调内完成，使用回调提供的 newURL；security scope 由根负责（不在子文件上重复开）。
        let imported: (hash: String, size: UInt64) = try await FolderBookmarks.withScope(root.url) { _ in
            var lastError: Error?
            for _ in 0..<2 {
                do {
                    // 协调回调（同步）里只打开文件句柄；fd 在句柄关闭前有效，FFI 先 dup（#1126 契约）。
                    var handle: FileHandle?
                    var coordError: NSError?
                    self.coordinator.coordinate(readingItemAt: target, options: [], error: &coordError) { newURL in
                        handle = try? FileHandle(forReadingFrom: newURL)
                    }
                    if let coordError { throw FolderImportError(reason: "coordination failed: \(coordError.localizedDescription)") }
                    guard let handle else { throw FolderImportError(reason: "open failed after coordination") }
                    defer { try? handle.close() }
                    let r = try await self.provider.run { try $0.importMedia(path: target.path, fd: handle.fileDescriptor) }
                    // ADR：不静默复制回退。provider 的 fallback 语义：
                    //   small（≤16KiB inline）/ already_in_store = store 的预期形态，接受；
                    //   identity_mismatch / head_mismatch / reference_failed / changed_during_import /
                    //   no_path = 引用没成立且不是预期的 inline，按单张失败（不静默复制）。
                    let acceptedFallbacks: Set<String> = ["small", "already_in_store"]
                    if !r.byReference, let fallback = r.fallback, !acceptedFallbacks.contains(fallback) {
                        throw FolderImportError(reason: "reference import failed: \(fallback) (\(r.detail ?? ""))")
                    }
                    return (r.hash, r.size)
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
        AppLog.log("folder \(sourceId): imported bytes=\(imported.size) hash=\(imported.hash.prefix(16)) by_reference=true")
        return .imported(contentHash: imported.hash, sizeBytes: Int64(imported.size))
    }

    func importPicked(_ item: PickedItem) async throws -> ImportResult {
        throw PickedImportUnsupported()
    }

    /// 这份内容不再需要：幂等、不许抛（provider 侧 release 幂等）。
    func release(_ contentHash: String) {
        try? provider.ffi.release(hash: contentHash)
    }
}

struct FolderImportError: Error {
    let reason: String
}
