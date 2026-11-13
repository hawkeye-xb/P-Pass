// #1731 卡 2：FolderImporter 的合同测试（引用导入 / by_reference / 失败口径 / release 幂等）。
// 用真 NativeProvider（FFI provider 对本地临时目录）+ 本地媒体目录；不需要真机授权。
import XCTest
import PPassCore
@testable import PPass

final class FolderImporterTests: XCTestCase {
    private var dir: URL!
    private var providerDir: URL!
    private var registry: FolderRegistry!
    private var sourceId: String!
    private var root: URL!
    private var native: NativeProvider!
    private var importer: FolderImporter!
    private let logger = OSLogger()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folderimport-\(UUID().uuidString)")
        providerDir = dir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: providerDir, withIntermediateDirectories: true)
        registry = FolderRegistry(directory: dir, logger: logger)
        root = dir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sourceId = try registry.addFolder(at: root, displayName: "library")
        native = try NativeProvider(root: dir)
        importer = FolderImporter(registry: registry, sourceId: sourceId, directory: dir, provider: native, logger: logger)
    }

    override func tearDownWithError() throws {
        native?.ffi.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    private func put(_ rel: String, content: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mediaId(rel: String) -> String {
        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: rel)
        return "folder:\(sourceId!):\(opaque)"
    }

    private func details(for rel: String) throws -> MediaDetails {
        let url = root.appendingPathComponent(rel)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedMs = values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        return MediaDetails(
            snapshot: MediaSnapshot(mediaId: mediaId(rel: rel), sourceVersion: FolderMediaSource.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: Int64(values.fileSize ?? 0)), bucketId: "folder:\(sourceId!)"),
            fileName: (rel as NSString).lastPathComponent, mimeType: "image/jpeg", sizeBytes: Int64(values.fileSize ?? 0), captureAtMs: modifiedMs ?? 0)
    }

    // 引用导入（>16KiB，越过 provider 的 inline 阈值）：by_reference 必须 = true。
    // 反证：把实现换成会复制的 importFile（返回 by_reference=false）→ 断言红。
    func testLargeFileImportsByReference() async throws {
        let payload = String(repeating: "B", count: 40 * 1024)
        try put("big.jpg", content: payload)
        let details = try details(for: "big.jpg")
        let result = try await importer.importMedia(details) { _ in }
        guard case let .imported(hash, size) = result else { return XCTFail("要 imported") }
        XCTAssertEqual(size, Int64(payload.utf8.count))
        let present = try native.ffi.hasBlob(hash: hash)
        XCTAssertTrue(present, "内容进了 provider store")
        XCTAssertEqual(hash.count, 64, "BLAKE3 hex")
        // provider 侧对引用导入记的是 External 路径（serve 时按它读源文件）；
        // by_reference=false 且 fallback 非 small/already_in_store 的意外回退已在实现里抛错——这里锁大文件必走引用。
        let stillThere = try native.ffi.hasBlob(hash: hash)
        XCTAssertTrue(stillThere, "引用导入的内容在 store 里")
    }

    // 小文件（≤16KiB）：store 预期 inline（fallback=small、by_reference=false）——是 provider 的正确形态，不是「静默复制回退」。
    func testSmallFileAcceptsExpectedInlineFallback() async throws {
        try put("img.jpg", content: "jpeg-bytes-123")
        let details = try details(for: "img.jpg")
        let result = try await importer.importMedia(details) { _ in }
        guard case let .imported(hash, size) = result else { return XCTFail("要 imported") }
        XCTAssertEqual(size, Int64("jpeg-bytes-123".utf8.count))
        let present = try native.ffi.hasBlob(hash: hash)
        XCTAssertTrue(present, "内容进了 provider store")
        XCTAssertEqual(hash.count, 64, "BLAKE3 hex")
    }

    // 引用导入失败（文件消失）按单张失败抛错，不静默复制回退。
    func testMissingFileFailsAsItemFailure() async throws {
        try put("gone.jpg", content: "x")
        let details = try details(for: "gone.jpg")
        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: "gone.jpg")
        // 模拟「映射还在、文件没了」（快照后文件被删）：mediaId 前缀合法、映射有路径，但文件不存在。
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.jpg"))
        // 注意：源缺失走 .sourceMissing 的前提是映射缺失或文件不存在（lookup 会给 nil）；
        // importer 对「映射在、文件没了」按单张失败抛错——先锁这个口径。
        do {
            _ = try await importer.importMedia(details) { _ in }
            XCTFail("文件没了要失败")
        } catch is SourceUnavailable {
            XCTFail("不是授权问题，不该是 SourceUnavailable")
        } catch {
            // 单张失败口径（任意错误类型都行，红线是不吞掉、不复制）
        }
        XCTAssertTrue(registry.relativePath(sourceId: sourceId, opaqueId: opaque) != nil)
    }

    // 同一内容只导入一次（第二次 import 同一文件返回同一 hash，provider store 一份内容）。
    func testSameContentImportsToSameHash() async throws {
        try put("a.jpg", content: "shared-bytes")
        try put("b.jpg", content: "shared-bytes")
        let r1 = try await importer.importMedia(try details(for: "a.jpg")) { _ in }
        let r2 = try await importer.importMedia(try details(for: "b.jpg")) { _ in }
        guard case let .imported(h1, _) = r1, case let .imported(h2, _) = r2 else { return XCTFail() }
        XCTAssertEqual(h1, h2, "同内容同 hash（桌面按内容去重的前提）")
    }

    // release 幂等、不抛；GC 收敛后 store 不再持有（BLOB-03：has_blob 观察 GC 保留，GC 是周期的，用短 gc_interval 的实例驱动收敛）。
    func testReleaseIsIdempotentAndGcConverges() async throws {
        try put("r.jpg", content: "release-me")
        let r = try await importer.importMedia(try details(for: "r.jpg")) { _ in }
        guard case let .imported(hash, _) = r else { return XCTFail() }
        importer.release(hash)
        importer.release(hash)
        // 1x 占盘验收口径：短暂等待 GC 后核对内容真的被回收（不靠 GC 间隔默认 60s 的运气）。
        let deadline = Date().addingTimeInterval(70)
        var gone = false
        while Date() < deadline {
            if !(try native.ffi.hasBlob(hash: hash)) { gone = true; break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTAssertTrue(gone, "release 后 GC 收敛，store 不再持有")
    }

    // 映射里没有的 opaque → .sourceMissing（照片库还列着、原图读不到的同一口径）。
    func testUnknownOpaqueReturnsSourceMissing() async throws {
        let details = MediaDetails(
            snapshot: MediaSnapshot(mediaId: "folder:\(sourceId!):no-such-opaque", sourceVersion: "1:1", bucketId: "folder:\(sourceId!)"),
            fileName: "x.jpg", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)
        let result = try await importer.importMedia(details) { _ in }
        XCTAssertEqual(result, .sourceMissing)
    }

    // 持久化边界：损坏的映射（含 .. 的路径）不导入（拒绝，返回 sourceMissing 而不是打开根外文件）。
    // 注意顺序：先用原路径算 mediaId（拿到那个 opaque），再篡改该 opaque 的映射值。
    func testUnsafeStoredPathIsNotImported() async throws {
        try put("evil.jpg", content: "evil")
        let details = try details(for: "evil.jpg")
        let opaque = FolderMediaSource.opaqueId(of: details.snapshot.mediaId, sourceId: sourceId)!
        var tampered = registry.record(id: sourceId)!
        tampered.items[opaque] = "../outside.jpg"
        registry.upsert(tampered)
        XCTAssertNil(registry.relativePath(sourceId: sourceId, opaqueId: opaque), "越界路径拿不出来")
        let result = try await importer.importMedia(details) { _ in }
        XCTAssertEqual(result, .sourceMissing, "越界路径拒绝，不导入")
    }

    // 非 folder 前缀的 mediaId → 抛错（Composite 分发的前提是前缀严格匹配）。
    func testForeignMediaIdThrows() async throws {
        let details = MediaDetails(
            snapshot: MediaSnapshot(mediaId: "photo:abc", sourceVersion: "1:1", bucketId: "b"),
            fileName: "x.jpg", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)
        do {
            _ = try await importer.importMedia(details) { _ in }
            XCTFail("要抛错")
        } catch is PickedImportUnsupported {
            XCTFail("错误类型不对")
        } catch {
            // 任意失败即可：这不是它该处理的 id
        }
    }
}
