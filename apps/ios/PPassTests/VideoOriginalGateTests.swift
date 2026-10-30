import Foundation
import PPassCore
import UIKit
import XCTest
@testable import PPass

/// 视频：翻到只显示封面，点了播放才取原片；电脑没给大小或手机空间不够就不开始；
/// 收到的字节超过声明大小立即中止（对位 Android `VideoPlaybackTest` / `DeclaredSizeGuardTest`）。
final class VideoOriginalGateTests: XCTestCase {
    private struct TicketTransport: CtrlTransport {
        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            try ProtoJSON.encode(Resp(id: "1", ok: true, result: try JSONValue.parse(Data(#"{"ticket":"t"}"#.utf8))))
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private let id = String(repeating: "cd", count: 32)
    private func video(bytes: Int64?) -> TimelineItem {
        TimelineItem(id: id, takenAt: Date(), isVideo: true, width: nil, height: nil, bytes: bytes, isMine: nil)
    }

    override func setUp() { try? FileManager.default.removeItem(at: LiveTimeline.videoCacheDir) }
    override func tearDown() { try? FileManager.default.removeItem(at: LiveTimeline.videoCacheDir) }

    private func timeline(free: Int64? = .max, counter: Counter,
                          _ fetch: @escaping (String, URL, @escaping @Sendable (UInt64) -> Void) async throws -> String) -> LiveTimeline {
        LiveTimeline(client: { ProtoClient(transport: TicketTransport()) }, myNodeId: { nil },
                     fetchBlob: { t, d, p in counter.hit(); return try await fetch(t, d, p) },
                     logger: OSLogger(), freeBytes: { free })
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: LiveTimeline.videoCacheDir.path)) ?? []
    }

    func test_download_aborts_when_received_bytes_exceed_declared_size() async throws {
        let counter = Counter()
        let id = self.id
        let tl = timeline(counter: counter) { _, dest, progress in
            try Data(count: 8).write(to: dest)
            progress(4)
            progress(9) // 超过声明的 8 字节
            try await Task.sleep(nanoseconds: 30_000_000_000) // 不中止就一直挂着
            return id
        }
        let started = Date()
        do {
            _ = try await tl.original(video(bytes: 8), progress: { _ in })
            XCTFail("oversize must fail")
        } catch let error as LiveTimeline.Failure {
            guard case let .exceedsDeclaredSize(declared, got) = error else { return XCTFail("wrong failure \(error)") }
            XCTAssertEqual(declared, 8)
            XCTAssertEqual(got, 9)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "aborted right away, not after the fake fetch ends")
        XCTAssertEqual(leftovers(), [], "nothing stays on disk")
    }

    /// 中止和最后一块数据赛跑、取回照样「成功」返回时，结果同样作废。
    func test_download_over_declared_size_is_refused_even_if_fetch_completes() async throws {
        let counter = Counter()
        let id = self.id
        let tl = timeline(counter: counter) { _, dest, progress in
            try Data(count: 12).write(to: dest)
            progress(12)
            return id
        }
        do {
            _ = try await tl.original(video(bytes: 8), progress: { _ in })
            XCTFail("oversize must fail")
        } catch let error as LiveTimeline.Failure {
            guard case .exceedsDeclaredSize = error else { return XCTFail("wrong failure \(error)") }
        }
        XCTAssertEqual(leftovers(), [])
    }

    func test_insufficient_space_does_not_start_download() async throws {
        let counter = Counter()
        let declared: Int64 = 500 * 1024 * 1024
        let tl = timeline(free: LiveTimeline.videoSpaceNeeded(declared) - 1, counter: counter) { _, _, _ in "" }
        do {
            _ = try await tl.original(video(bytes: declared), progress: { _ in })
            XCTFail("must refuse")
        } catch let error as LiveTimeline.Failure {
            guard case .noRoom = error else { return XCTFail("wrong failure \(error)") }
        }
        XCTAssertEqual(counter.count, 0, "no fetch started")
        // 反证：空间刚好够就开始取回。
        let id = self.id
        let ok = timeline(free: LiveTimeline.videoSpaceNeeded(4), counter: counter) { _, dest, _ in
            try Data(count: 4).write(to: dest); return id
        }
        _ = try await ok.original(video(bytes: 4), progress: { _ in })
        XCTAssertEqual(counter.count, 1)
    }

    func test_space_check_counts_scratch_copy_and_export() {
        XCTAssertEqual(LiveTimeline.videoSpaceNeeded(1_000), 2_000 + 64 * 1024 * 1024)
    }

    func test_unknown_video_size_does_not_start_download() async {
        let counter = Counter()
        let tl = timeline(counter: counter) { _, _, _ in "" }
        for bytes: Int64? in [nil, 0] {
            do {
                _ = try await tl.original(video(bytes: bytes), progress: { _ in })
                XCTFail("must refuse")
            } catch let error as LiveTimeline.Failure {
                guard case .unknownSize = error else { return XCTFail("wrong failure \(error)") }
            } catch { XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: 查看器的视频页

    private final class CountingSource: TimelineSource, @unchecked Sendable {
        let originals = Counter()
        let url: URL
        init(url: URL) { self.url = url }
        func page(cursor: String?, reason: TimelinePageReason) async throws -> PPass.TimelinePage { .init(items: [], nextCursor: nil) }
        func thumbnail(_ item: TimelineItem, large: Bool) async throws -> UIImage { UIImage() }
        func cachedOriginal(_ item: TimelineItem) -> URL? { nil }
        func original(_ item: TimelineItem, progress: @escaping (Double) -> Void) async throws -> URL {
            originals.hit(); progress(1); return url
        }
    }

    @MainActor
    func test_opening_video_page_does_not_download() async throws {
        let source = CountingSource(url: URL(fileURLWithPath: "/tmp/x.mov"))
        // 翻页 = 为每一页建一个模型（ViewerPage 的 @StateObject）；没点播放就不取原片。
        let pages = (0..<5).map { _ in VideoPlaybackModel(item: video(bytes: 8), timeline: source) }
        try await Task.sleep(nanoseconds: 100_000_000)
        pages.forEach { XCTAssertEqual($0.phase, .cover) }
        XCTAssertEqual(source.originals.count, 0)
    }

    @MainActor
    func test_tapping_play_fetches_once_then_plays() async throws {
        let url = URL(fileURLWithPath: "/tmp/x.mov")
        let source = CountingSource(url: url)
        let model = VideoPlaybackModel(item: video(bytes: 8), timeline: source)
        model.play()
        model.play() // 正在取：重复点击忽略
        let deadline = Date().addingTimeInterval(5)
        while model.phase != .ready(url), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.phase, .ready(url))
        model.play() // 已就绪：不重取
        XCTAssertEqual(source.originals.count, 1)
    }

    /// 反证：在页面出现时（`.task` / `onAppear`）直接取原片 ⇒ 红。
    func test_viewer_page_only_fetches_original_from_play_button() throws {
        let src = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Photos/MediaViewer.swift"), encoding: .utf8)
        let page = try XCTUnwrap(src.range(of: "private struct ViewerPage")).lowerBound
        let pageEnd = try XCTUnwrap(src.range(of: "private struct VideoCover")).lowerBound
        XCTAssertFalse(src[page..<pageEnd].contains("timeline.original("), "ViewerPage must not fetch originals itself")
        XCTAssertTrue(src[page..<pageEnd].contains("onPlay: video.play"))
    }
}
