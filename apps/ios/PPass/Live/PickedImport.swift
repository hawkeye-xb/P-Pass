import Foundation
import Photos
import PPassCore
import UniformTypeIdentifiers

/// #1272 B：有限访问时用户在系统框里允许的那些照片（相册里的 asset）。传法同手选：轮到时才取原图，不复制整批。
struct PHAssetPayload: PickedPayload, @unchecked Sendable {
    let localIdentifier: String

    /// 系统此刻允许 P-Pass 看到的静态图片（有限访问下只含用户允许的）。
    static func allowedImages() -> [(fileName: String, mimeType: String, payload: PickedPayload)] {
        let result = PHAsset.fetchAssets(with: .image, options: nil)
        var out: [(fileName: String, mimeType: String, payload: PickedPayload)] = []
        result.enumerateObjects { asset, index, _ in
            let resource = PHAssetResource.assetResources(for: asset).first { $0.type == .photo || $0.type == .fullSizePhoto }
            let name = resource?.originalFilename ?? "IMG_\(index + 1).jpg"
            let mime = resource.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType } ?? "image/jpeg"
            out.append((name, mime, PHAssetPayload(localIdentifier: asset.localIdentifier)))
        }
        return out
    }
}

/// #1272 挑几张传：PHPicker 给回的一张。`NSItemProvider` 只在本进程存活期间有效，所以只存句柄、不复制照片；
/// 轮到这一张时才 `loadFileRepresentation`（系统给的临时文件在回调结束就删，所以在回调里立刻拷到 App 自己的临时目录）。
struct PHPickedPayload: PickedFilePayload, @unchecked Sendable {
    let provider: NSItemProvider
    let type: UTType

    /// 这张的文件名与 MIME（选择器不给 assetIdentifier，也没有拍摄时间）。只接受照片或视频。
    static func describe(_ provider: NSItemProvider, index: Int) -> (name: String, mime: String, payload: PickedPayload)? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard let type = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) }) else { return nil }
        let isImage = type.conforms(to: .image)
        let base = (provider.suggestedName ?? "").isEmpty ? "PICK_\(index + 1)" : provider.suggestedName!
        let ext = type.preferredFilenameExtension ?? (isImage ? "jpg" : "mov")
        let name = base.lowercased().hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
        let fallback = isImage ? "image/jpeg" : "video/quicktime"
        return (name, type.preferredMIMEType ?? fallback, PHPickedPayload(provider: provider, type: type))
    }

    /// 取这一张的原始文件，拷进 [directory] 下一个独立子目录，返回拷贝的路径。响应 Task 取消（停掉系统的加载）。
    func copy(into directory: URL, fileName: String) async throws -> URL {
        let fm = FileManager.default
        let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((fileName as NSString).lastPathComponent)
        let progress = ProgressBox()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    progress.set(provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        guard let url else { return cont.resume(throwing: error ?? PickedLoadError.noFile) }
                        do {
                            try fm.copyItem(at: url, to: dest) // 回调一返回，系统就删 url：必须在这里拷
                            cont.resume()
                        } catch { cont.resume(throwing: error) }
                    })
                }
            } onCancel: { progress.cancel() }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        if Task.isCancelled { try? fm.removeItem(at: dir); throw CancellationError() }
        return dest
    }
}

struct FilePickedPayload: PickedFilePayload, @unchecked Sendable {
    let url: URL
    let type: UTType
    let selectionLimit: Int?
    let coordinateRead: (URL, (URL) -> Void) -> NSError?

    static func coordinateFile(at url: URL, accessor: (URL) -> Void) -> NSError? {
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { newURL in
            accessor(newURL)
        }
        return error
    }

    init(url: URL, type: UTType, selectionLimit: Int? = nil, coordinateRead: @escaping (URL, (URL) -> Void) -> NSError? = FilePickedPayload.coordinateFile) {
        self.url = url
        self.type = type
        self.selectionLimit = selectionLimit
        self.coordinateRead = coordinateRead
    }

    static func describe(_ url: URL, index: Int) -> (name: String, mime: String, payload: PickedPayload)? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) else { return nil }
        let name = url.lastPathComponent.isEmpty ? "FILE_\(index + 1)" : url.lastPathComponent
        let fallback = type.conforms(to: .image) ? "image/jpeg" : "video/quicktime"
        return (name, type.preferredMIMEType ?? fallback, FilePickedPayload(url: url, type: type))
    }

    /// 只在读取这一张时持有安全作用域；provider 按引用导入后仍使用 App 自己持有的副本。
    func copy(into directory: URL, fileName: String) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((fileName as NSString).lastPathComponent)
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var copyError: Error?
            let coordinationError = coordinateRead(url) { coordinatedURL in
                do { try fm.copyItem(at: coordinatedURL, to: dest) } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            try Task.checkCancellation()
            return dest
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }
}

enum PickedLoadError: Error { case noFile }

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false
    func set(_ p: Progress) { lock.lock(); progress = p; let c = cancelled; lock.unlock(); if c { p.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let p = progress; lock.unlock(); p?.cancel() }
}
