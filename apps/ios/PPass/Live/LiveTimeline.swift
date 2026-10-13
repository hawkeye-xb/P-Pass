import Foundation
import PPassCore
import UIKit

/// 时间线 = 电脑照片库（`timeline.page` + `thumb.get`，对位 Android TimelineLoader）。缩略图只在内存里缓存。
/// 「仅本机 / 家人的」按 `src_device` 是否等于本机 NodeId 区分；src_device 为空的只出现在「全部」里。
final class LiveTimeline: TimelineSource, @unchecked Sendable {
    private let client: () -> ProtoClient?
    private let myNodeId: () -> String?
    private let cache = NSCache<NSString, UIImage>()

    init(client: @escaping () -> ProtoClient?, myNodeId: @escaping () -> String?) {
        self.client = client
        self.myNodeId = myNodeId
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

    /// 取原图要 iroh-blobs 的下载端（`asset.blob_ticket` → 拉 blob）。传输 FFI 目前只导出了供数端，
    /// 没有下载端——这一项如实失败（查看器显示「没取到」），不在 App 里另写一个下载器。
    func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL {
        throw Failure.originalUnsupported
    }
}
