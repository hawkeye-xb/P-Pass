import Foundation
import PPassCore
import UIKit
import XCTest
@testable import PPass

/// 电脑发来的缩略图：只认 JPEG，宽高都不超过 1024（对位 Android `DesktopThumbTest`）。
/// 图片是现场编码的真 JPEG / PNG，判定走真实的 `CGImageSource`。
final class DesktopThumbTests: XCTestCase {
    private func image(_ w: Int, _ h: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private func jpeg(_ w: Int, _ h: Int) -> Data { image(w, h).jpegData(compressionQuality: 0.8)! }

    func test_thumbnail_rejects_non_jpeg() {
        let png = image(64, 64).pngData()!
        XCTAssertThrowsError(try DesktopThumb.decode(png)) { XCTAssertEqual($0 as? DesktopThumb.Rejection, .notJpeg) }
        XCTAssertThrowsError(try DesktopThumb.decode(Data([0x47, 0x49, 0x46, 0x38]))) { XCTAssertEqual($0 as? DesktopThumb.Rejection, .notJpeg) }
        XCTAssertThrowsError(try DesktopThumb.decode(Data())) { XCTAssertEqual($0 as? DesktopThumb.Rejection, .notJpeg) }
        // JPEG 魔数开头、文件头却说是别的类型：同样拒绝。
        XCTAssertEqual(DesktopThumb.judge(magicOk: true, typeIdentifier: "public.png", width: 64, height: 64), .notJpeg)
    }

    func test_thumbnail_rejects_edge_over_1024() {
        XCTAssertThrowsError(try DesktopThumb.decode(jpeg(1025, 10))) {
            XCTAssertEqual($0 as? DesktopThumb.Rejection, .tooLarge(width: 1025, height: 10))
        }
        XCTAssertThrowsError(try DesktopThumb.decode(jpeg(10, 1025))) {
            XCTAssertEqual($0 as? DesktopThumb.Rejection, .tooLarge(width: 10, height: 1025))
        }
    }

    func test_thumbnail_accepts_jpeg_up_to_1024() throws {
        let img = try DesktopThumb.decode(jpeg(1024, 683))
        XCTAssertEqual(img.cgImage?.width, 1024)
        XCTAssertEqual(img.cgImage?.height, 683)
        XCTAssertNoThrow(try DesktopThumb.decode(jpeg(256, 171)))
    }

    func test_thumbnail_rejects_truncated_jpeg_header() {
        XCTAssertThrowsError(try DesktopThumb.decode(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])))
    }

    // MARK: 经 LiveTimeline.thumbnail 的整条路径

    private struct ThumbTransport: CtrlTransport {
        let payload: Data
        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            let body = try ProtoJSON.encode(ThumbData(jpegBase64: payload.base64EncodedString()))
            return try ProtoJSON.encode(Resp(id: "1", ok: true, result: try JSONValue.parse(body)))
        }
    }

    private final class Lines: CoreLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func log(_ line: String) { lock.withLock { all.append(line) } }
        var lines: [String] { lock.withLock { all } }
    }

    private func thumb(_ payload: Data, logger: Lines) async throws -> UIImage {
        let tl = LiveTimeline(client: { ProtoClient(transport: ThumbTransport(payload: payload)) }, myNodeId: { nil },
                              fetchBlob: { _, _, _ in "" }, logger: logger)
        let item = TimelineItem(id: String(repeating: "ab", count: 32), takenAt: Date(), isVideo: false,
                                width: nil, height: nil, bytes: nil, isMine: nil)
        return try await tl.thumbnail(item, large: true)
    }

    func test_timeline_thumbnail_rejects_png_and_logs_it() async {
        let log = Lines()
        do {
            _ = try await thumb(image(64, 64).pngData()!, logger: log)
            XCTFail("PNG must be rejected")
        } catch {
            XCTAssertEqual(error as? DesktopThumb.Rejection, .notJpeg)
        }
        XCTAssertTrue(log.lines.contains { $0.contains("thumb.get size=1024 failed (rejected: not JPEG)") }, "\(log.lines)")
    }

    func test_timeline_thumbnail_rejects_oversized_jpeg_and_logs_it() async {
        let log = Lines()
        do {
            _ = try await thumb(jpeg(2048, 1536), logger: log)
            XCTFail("2048 must be rejected")
        } catch {
            XCTAssertEqual(error as? DesktopThumb.Rejection, .tooLarge(width: 2048, height: 1536))
        }
        XCTAssertTrue(log.lines.contains { $0.contains("rejected: too large 2048x1536") }, "\(log.lines)")
    }

    func test_timeline_thumbnail_accepts_desktop_jpeg() async throws {
        let log = Lines()
        let img = try await thumb(jpeg(1024, 768), logger: log)
        XCTAssertEqual(img.cgImage?.width, 1024)
    }

    /// 反证：把 `thumbnail` 改回 `UIImage(data:)` 直接解码 ⇒ 红。
    func test_live_timeline_does_not_decode_thumbnails_directly() throws {
        let src = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Live/LiveTimeline.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("UIImage(data:"))
        XCTAssertTrue(src.contains("try DesktopThumb.decode(bytes)"))
    }
}
