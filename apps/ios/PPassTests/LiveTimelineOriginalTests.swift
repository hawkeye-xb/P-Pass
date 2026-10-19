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
}
