import Foundation
import PPassCore
import XCTest
@testable import PPass

/// 取原图（#953）：哈希校验、取消清半截文件、tmp/ppass-share 即用即清。
final class LiveTimelineOriginalTests: XCTestCase {
    private struct TicketTransport: CtrlTransport {
        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            let result = try JSONValue.parse(Data(#"{"ticket":"t"}"#.utf8))
            return try ProtoJSON.encode(Resp(id: "1", ok: true, result: result))
        }
    }

    private let id = String(repeating: "ab", count: 32)
    private var item: TimelineItem {
        TimelineItem(id: id, takenAt: Date(), isVideo: false, width: nil, height: nil, bytes: 4, isMine: nil)
    }

    override func setUp() { LiveTimeline.clearShareDir() }
    override func tearDown() { LiveTimeline.clearShareDir() }

    private func timeline(_ fetch: @escaping (String, URL, @escaping @Sendable (UInt64) -> Void) async throws -> String) -> LiveTimeline {
        LiveTimeline(client: { ProtoClient(transport: TicketTransport()) }, myNodeId: { nil }, fetchBlob: fetch, logger: OSLogger())
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: LiveTimeline.shareDir.path)) ?? [])
    }

    func test_matching_hash_returns_file_and_discard_removes_it() async throws {
        let id = self.id
        let tl = timeline { _, dest, _ in
            try Data([0xFF, 0xD8, 0, 0]).write(to: dest)
            return id.uppercased() // 大小写不敏感
        }
        let url = try await tl.original(item, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        LiveTimeline.discardShared(url)
        XCTAssertEqual(leftovers(), [])
    }

    func test_hash_mismatch_throws_and_deletes_file() async throws {
        let tl = timeline { _, dest, _ in
            try Data([1, 2, 3, 4]).write(to: dest)
            return String(repeating: "00", count: 32)
        }
        do {
            _ = try await tl.original(item, progress: { _ in })
            XCTFail("hash mismatch must throw")
        } catch let error as LiveTimeline.Failure {
            guard case .hashMismatch = error else { return XCTFail("wrong failure \(error)") }
        }
        XCTAssertEqual(leftovers(), [], "mismatched content must not stay on disk")
    }

    func test_cancellation_aborts_and_removes_partial_file() async throws {
        let tl = timeline { _, dest, _ in
            try Data([1, 2]).write(to: dest) // 半截
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return ""
        }
        let item = self.item
        let task = Task { try await tl.original(item, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled fetch must throw")
        } catch is CancellationError {}
        XCTAssertEqual(leftovers(), [])
    }

    func test_clearShareDir_removes_residue() throws {
        try FileManager.default.createDirectory(at: LiveTimeline.shareDir, withIntermediateDirectories: true)
        try Data([1]).write(to: LiveTimeline.shareDir.appendingPathComponent("old.jpg"))
        LiveTimeline.clearShareDir()
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: #1149 桌面给的 hash 先验格式再拼路径

    private func item(id: String, isVideo: Bool = false) -> TimelineItem {
        TimelineItem(id: id, takenAt: Date(), isVideo: isVideo, width: nil, height: nil, bytes: 4, isMine: nil)
    }

    func test_content_hash_format() {
        XCTAssertTrue(LiveTimeline.isContentHash(id))
        XCTAssertTrue(LiveTimeline.isContentHash(id.uppercased()))
        for bad in ["", "ab", String(repeating: "ab", count: 31), String(repeating: "ab", count: 33),
                    String(repeating: "zz", count: 32), "../" + String(repeating: "a", count: 61),
                    String(repeating: "a", count: 63) + "/", String(repeating: "a", count: 63) + "\u{0}",
                    String(repeating: "é", count: 32)] {
            XCTAssertFalse(LiveTimeline.isContentHash(bad), "\(bad.debugDescription) must not pass")
        }
    }

    /// 反证：去掉 `original` 开头的校验 ⇒ 抓取回调被调用 / 目录被建出来 ⇒ 变红。
    func test_malformed_hash_is_refused_without_touching_the_cache_dirs() async throws {
        let fetched = Mutex()
        let tl = timeline { _, _, _ in fetched.hit(); return "" }
        for bad in ["", "../evil", String(repeating: "x", count: 64), "ab"] {
            for video in [false, true] {
                do {
                    _ = try await tl.original(item(id: bad, isVideo: video), progress: { _ in })
                    XCTFail("\(bad.debugDescription) must be refused")
                } catch let error as LiveTimeline.Failure {
                    guard case .invalidContentHash = error else { return XCTFail("wrong failure \(error)") }
                }
            }
        }
        XCTAssertEqual(fetched.count, 0, "nothing is fetched for an invalid id")
        XCTAssertFalse(FileManager.default.fileExists(atPath: LiveTimeline.shareDir.path), "share dir untouched")
    }

    /// 空串 hash 的 `hasPrefix("")` 恒真：没有校验时会把视频缓存目录里所有文件当残留删掉。
    func test_empty_hash_does_not_wipe_the_video_cache() throws {
        let dir = LiveTimeline.videoCacheDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keep = dir.appendingPathComponent(String(repeating: "cd", count: 32) + ".mov")
        try Data([1, 2, 3, 4]).write(to: keep)
        defer { try? FileManager.default.removeItem(at: keep) }
        let tl = timeline { _, _, _ in "" }
        XCTAssertNil(tl.cachedOriginal(item(id: "", isVideo: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "another video's cache survives")
    }

    private final class Mutex: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
