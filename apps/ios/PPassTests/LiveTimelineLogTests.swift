import Foundation
import PPassCore
import UIKit
import XCTest
@testable import PPass

/// #987：照片页的 timeline.page / thumb.get 每次请求一行日志——方法、为什么取、结果、耗时；不带哈希。
final class LiveTimelineLogTests: XCTestCase {
    private final class Lines: CoreLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        func log(_ message: String) { lock.lock(); stored.append(message); lock.unlock() }
    }

    /// 按方法名给应答；没登记的方法 = 连不上（抛）。
    private struct Replies: CtrlTransport {
        let byMethod: [String: Data]
        struct Unreachable: Error {}
        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            guard let body = byMethod[method] else { throw Unreachable() }
            return try ProtoJSON.encode(Resp(id: "1", ok: true, result: try JSONValue.parse(body)))
        }
    }

    private let contentHash = String(repeating: "cd", count: 32)

    private func timeline(_ replies: [String: String], _ lines: Lines) -> LiveTimeline {
        let transport = Replies(byMethod: replies.mapValues { Data($0.utf8) })
        return LiveTimeline(client: { ProtoClient(transport: transport) }, myNodeId: { nil },
                            fetchBlob: { _, _, _ in "" }, logger: lines)
    }

    private var item: TimelineItem {
        TimelineItem(id: contentHash, takenAt: Date(), isVideo: false, width: nil, height: nil, bytes: nil, isMine: nil)
    }

    func test_page_success_logs_reason_count_and_duration() async throws {
        let lines = Lines()
        let tl = timeline([Methods.timelinePage: #"{"items":[],"next":"c2"}"#], lines)
        _ = try await tl.page(cursor: nil, reason: .signal)
        XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
        let line = try XCTUnwrap(lines.all.first)
        XCTAssertTrue(line.hasPrefix("timeline.page reason=signal cursor=first ok items=0 more=true in "), line)
        XCTAssertTrue(line.hasSuffix("ms"), line)
    }

    func test_page_failure_logs_error_category() async {
        let lines = Lines()
        let tl = timeline([:], lines)
        _ = try? await tl.page(cursor: "c2", reason: .more)
        XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
        XCTAssertTrue(lines.all.first?.hasPrefix("timeline.page reason=more cursor=next failed (Unreachable) in ") == true, "\(lines.all)")
    }

    func test_thumb_success_logs_without_hash_and_cache_hit_is_silent() async throws {
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).jpegData(withCompressionQuality: 0.5) { _ in })
        let lines = Lines()
        let tl = timeline([Methods.thumbGet: #"{"jpeg_base64":"\#(jpeg.base64EncodedString())"}"#], lines)
        _ = try await tl.thumbnail(item, large: false)
        _ = try await tl.thumbnail(item, large: false) // 内存缓存命中：不是请求，不记
        XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
        let line = try XCTUnwrap(lines.all.first)
        XCTAssertTrue(line.hasPrefix("thumb.get size=256 ok in "), line)
        XCTAssertFalse(lines.all.joined().contains(contentHash.prefix(16)), "日志不带哈希")
    }

    func test_thumb_placeholder_is_its_own_category() async {
        let lines = Lines()
        let tl = timeline([Methods.thumbGet: #"{"jpeg_base64":"","placeholder":true}"#], lines)
        _ = try? await tl.thumbnail(item, large: true)
        XCTAssertTrue(lines.all.first?.hasPrefix("thumb.get size=1024 failed (thumbnail not ready) in ") == true, "\(lines.all)")
    }
}
