import AVFoundation
import Foundation
import UIKit

/// 演示时间线：三个月、45 张，其中每 7 张一个视频；一半是本机拍的、一半是家人的。
final class FakeTimeline: TimelineSource {
    private let scenario: FakeScenario
    private lazy var items: [TimelineItem] = {
        let now = Date()
        var out: [TimelineItem] = []
        for i in 0..<45 {
            let age: TimeInterval = Double(i) * 86_400 * 2.1
            let id = String(format: "%064x", i + 1)
            out.append(TimelineItem(id: id, takenAt: now.addingTimeInterval(-age), isVideo: i % 7 == 3,
                                    width: 4032, height: 3024, bytes: 2_400_000, isMine: i % 2 == 0))
        }
        return out
    }()

    init(scenario: FakeScenario) { self.scenario = scenario }

    func page(cursor: String?, reason: TimelinePageReason) async throws -> TimelinePage {
        switch scenario {
        case .timelineLoading:
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        case .timelineError:
            try await Task.sleep(nanoseconds: 400_000_000)
            throw FakeError.unreachable
        case .timelineEmpty:
            return TimelinePage(items: [], nextCursor: nil)
        default:
            break
        }
        let start = Int(cursor ?? "0") ?? 0
        let end = min(start + 30, items.count)
        return TimelinePage(items: Array(items[start..<end]), nextCursor: end < items.count ? String(end) : nil)
    }

    func thumbnail(_ item: TimelineItem, large: Bool) async throws -> UIImage {
        let side: CGFloat = large ? 900 : 240
        return FakeImages.tile(seed: item.id.hashValue, size: CGSize(width: side, height: side * 0.75))
    }

    func cachedOriginal(_ item: TimelineItem) -> URL? { nil }
    func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL {
        for step in 1...5 {
            try await Task.sleep(nanoseconds: 150_000_000)
            progress(Double(step) / 5)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-originals", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if item.isVideo {
            let url = dir.appendingPathComponent("\(item.id.suffix(8)).mp4")
            if !FileManager.default.fileExists(atPath: url.path) { try await FakeImages.writeVideo(to: url) }
            return url
        }
        let url = dir.appendingPathComponent("\(item.id.suffix(8)).jpg")
        let image = FakeImages.tile(seed: item.id.hashValue, size: CGSize(width: 1600, height: 1200))
        try image.jpegData(compressionQuality: 0.85)?.write(to: url)
        return url
    }
}

enum FakeError: Error { case unreachable }

/// 演示用图：用 token 色画的纯色块 + 斜纹（不是真照片，截图里一眼能认出是演示数据）。
enum FakeImages {
    private static let palette: [UIColor] = [
        UIColor(PPColor.canvas), UIColor(PPColor.safeBg), UIColor(PPColor.waitingBg),
        UIColor(PPColor.idleBg), UIColor(PPColor.hairline), UIColor(PPColor.linen),
    ]

    static func tile(seed: Int, size: CGSize) -> UIImage {
        let base = palette[abs(seed) % palette.count]
        let stripe = UIColor(PPColor.ink40).withAlphaComponent(0.18)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            stripe.setStroke()
            let path = UIBezierPath()
            let step = max(size.width, size.height) / 6
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            path.lineWidth = step / 6
            path.stroke()
        }
    }

    /// 两秒的演示视频（逐帧画色块），给视频页一个真能播的文件。
    static func writeVideo(to url: URL) async throws {
        let size = CGSize(width: 640, height: 480)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<48 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer, let cg = tile(seed: frame / 12, size: size).cgImage else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(cg, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? FakeError.unreachable }
    }
}
