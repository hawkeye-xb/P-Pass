import Foundation
import PPassCore
import UniformTypeIdentifiers

/// #1272 挑几张传：PHPicker 给回的一张。`NSItemProvider` 只在本进程存活期间有效，所以只存句柄、不复制照片；
/// 轮到这一张时才 `loadFileRepresentation`（系统给的临时文件在回调结束就删，所以在回调里立刻拷到 App 自己的临时目录）。
struct PHPickedPayload: PickedPayload, @unchecked Sendable {
    let provider: NSItemProvider
    let type: UTType

    /// 这张的文件名与 MIME（选择器不给 assetIdentifier，也没有拍摄时间）。不是静态图片（如 Live Photo 的 bundle）= nil。
    static func describe(_ provider: NSItemProvider, index: Int) -> (name: String, mime: String, payload: PickedPayload)? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard let type = types.first(where: { $0.conforms(to: .image) }) else { return nil }
        let base = (provider.suggestedName ?? "").isEmpty ? "IMG_\(index + 1)" : provider.suggestedName!
        let ext = type.preferredFilenameExtension ?? "jpg"
        let name = base.lowercased().hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
        return (name, type.preferredMIMEType ?? "image/jpeg", PHPickedPayload(provider: provider, type: type))
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

enum PickedLoadError: Error { case noFile }

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false
    func set(_ p: Progress) { lock.lock(); progress = p; let c = cancelled; lock.unlock(); if c { p.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let p = progress; lock.unlock(); p?.cancel() }
}
