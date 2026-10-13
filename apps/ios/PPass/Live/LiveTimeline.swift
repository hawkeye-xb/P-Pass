import Foundation
import PPassCore
import UIKit

/// 时间线 = 电脑照片库（`timeline.page` + `thumb.get`，对位 Android TimelineLoader）。缩略图只在内存里缓存。
/// 「仅本机 / 家人的」按 `src_device` 是否等于本机 NodeId 区分；src_device 为空的只出现在「全部」里。
final class LiveTimeline: TimelineSource, @unchecked Sendable {
    private let client: () -> ProtoClient?
    private let myNodeId: () -> String?
    private let fetchBlob: (String, URL, @escaping @Sendable (UInt64) -> Void) async throws -> Void
    private let cache = NSCache<NSString, UIImage>()

    init(client: @escaping () -> ProtoClient?, myNodeId: @escaping () -> String?,
         fetchBlob: @escaping (String, URL, @escaping @Sendable (UInt64) -> Void) async throws -> Void) {
        self.client = client
        self.myNodeId = myNodeId
        self.fetchBlob = fetchBlob
    }

    enum Failure: Error, CustomStringConvertible {
        case notPaired, placeholder, originalUnsupported
        var description: String {
            switch self {
            case .notPaired: return "not paired"
            case .placeholder: return "thumbnail not ready"
            case .originalUnsupported: return "original download is not available on iOS yet"
            }
        }
    }

    func page(cursor: String?) async throws -> TimelinePage {
        guard let client = client() else { throw Failure.notPaired }
        let page = try await client.call(Methods.timelinePage, TimelineQuery(cursor: cursor, limit: 60), as: PPassCore.TimelinePage.self)
        let me = myNodeId()
        let items = page.items.map { m in
            TimelineItem(id: m.hash, takenAt: Date(timeIntervalSince1970: Double(m.takenAt)),
                         isVideo: m.mediaType == "video" || m.mediaType.hasPrefix("video/"),
                         width: m.width > 0 ? Int(m.width) : nil, height: m.height > 0 ? Int(m.height) : nil,
                         bytes: m.bytes > 0 ? Int64(m.bytes) : nil,
                         isMine: (m.srcDevice?.isEmpty == false) ? (m.srcDevice == me) : nil)
        }
        return TimelinePage(items: items, nextCursor: page.next)
    }

    func thumbnail(_ item: TimelineItem, large: Bool) async throws -> UIImage {
        let key = "\(item.id)-\(large ? 1024 : 256)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let client = client() else { throw Failure.notPaired }
        let data = try await client.call(Methods.thumbGet, ThumbGet(hash: item.id, size: large ? .s1024 : .s256), as: ThumbData.self)
        guard !data.placeholder, let bytes = Data(base64Encoded: data.jpegBase64), let image = UIImage(data: bytes) else {
            throw Failure.placeholder
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 取原图（RET-01：取回 = 使用动作）：问电脑要 `asset.blob_ticket`，再走 iroh-blobs 拉回来。
    /// 照片即用即清（`tmp/ppass-share/`，不建长期原图缓存）；视频与 Android 一样进缓存目录，按字节数校验后复用——
    /// 滑过再滑回来不会重下（系统在空间紧张时会清 Caches，手机是减负端不是第二存储端）。
    func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let dir = item.isVideo
            ? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ppass-videos", isDirectory: true)
            : fm.temporaryDirectory.appendingPathComponent("ppass-share", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if item.isVideo, let hit = Self.completeCached(item, in: dir) { return hit }

        guard let client = client() else { throw Failure.notPaired }
        let ticket = try await client.call(Methods.assetBlobTicket, BlobTicketRequest(hash: item.id), as: BlobTicketResponse.self).ticket
        let raw = dir.appendingPathComponent(item.id + ".part")
        try? fm.removeItem(at: raw)
        let total = Double(max(item.bytes ?? 0, 1))
        do {
            try await fetchBlob(ticket, raw) { bytes in progress(min(Double(bytes) / total, 1)) }
        } catch {
            try? fm.removeItem(at: raw) // 失败不留半截文件
            throw error
        }
        // 线上只有内容哈希、没有文件名：按文件头认格式，补上扩展名（分享面板 / 存相册靠它识别）。
        let named = dir.appendingPathComponent(item.id).appendingPathExtension(Self.fileExtension(of: raw, isVideo: item.isVideo))
        try? fm.removeItem(at: named)
        try fm.moveItem(at: raw, to: named)
        return named
    }

    /// 缓存命中判据同 Android MOB-115：文件长度必须等于元数据里的字节数；不符或无从校验就删掉重下。
    private static func completeCached(_ item: TimelineItem, in dir: URL) -> URL? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for f in files where f.lastPathComponent.hasPrefix(item.id) {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if f.pathExtension != "part", let want = item.bytes, want > 0, size == want { return f }
            try? fm.removeItem(at: f)
        }
        return nil
    }

    static func fileExtension(of url: URL, isVideo: Bool) -> String {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 16) else { return isVideo ? "mov" : "jpg" }
        try? h.close()
        let b = [UInt8](head)
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            switch String(decoding: b[8..<12], as: UTF8.self) {
            case "heic", "heix", "hevc", "mif1", "msf1", "heif": return "heic"
            case "qt  ": return "mov"
            default: return isVideo ? "mp4" : "heic"
            }
        }
        return isVideo ? "mov" : "jpg"
    }
}
