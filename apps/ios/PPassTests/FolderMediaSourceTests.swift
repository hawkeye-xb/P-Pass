// #1731 卡 2：FolderMediaSource 的合同测试（游标契约 / 过滤 / 版本 / 授权失效口径）。
import XCTest
import PPassCore
@testable import PPass

final class FolderMediaSourceTests: XCTestCase {
    private var dir: URL!
    private var registry: FolderRegistry!
    private var source: FolderMediaSource!
    private var sourceId: String!
    private var root: URL!
    private let logger = OSLogger()

    override func setUpWithError() throws {
        dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        registry = FolderRegistry(directory: dir, logger: logger)
        root = dir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sourceId = try registry.addFolder(at: root, displayName: "library")
        source = FolderMediaSource(registry: registry, sourceId: sourceId, directory: dir, logger: logger)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func put(_ rel: String, content: String = "data") throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func putVideo(_ rel: String) throws { try put(rel, content: "video") }

    // 嵌套目录递归 + 类型过滤：图片/视频计入，非媒体忽略不计失败；symlink 跳过不跟随。
    func testRecursiveEnumerationFiltersTypesAndSkipsSymlinks() async throws {
        try put("a.jpg")
        try putVideo("nested/b.mov")
        try put("notes.txt")
        try put("song.m4a")
        let link = root.appendingPathComponent("link-to-a.jpg")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("a.jpg"))

        let batch = try await source.inScope(after: nil, limit: 100)
        XCTAssertEqual(batch.count, 2, "只有 a.jpg 与 nested/b.mov")
        // symlink 不跟随、不计入。
        // symlink 不跟随、不计入。
        let linkItems = registry.record(id: sourceId)?.items.values.filter { $0.hasSuffix("link-to-a.jpg") } ?? []
        XCTAssertTrue(linkItems.isEmpty, "symlink 跳过")
    }

    // 游标契约四条：changes 恒空、folder-v1 占位、libraryIdentity nil、preciseDiscovery false。
    func testCursorContract() async throws {
        let empty = try await source.changes(after: DiscoveryPosition(raw: Data(FolderMediaSource.positionPlaceholder.utf8)), limit: 10)
        XCTAssertTrue(empty.isEmpty, "目录新项不依赖 incremental changes")
        let position = try await source.currentPosition()
        XCTAssertEqual(String(decoding: position.raw, as: UTF8.self), "folder-v1")
        let identity = try await source.libraryIdentity()
        XCTAssertNil(identity, "不因占位位置触发重置")
        XCTAssertFalse(source.preciseDiscovery, "每轮由 inScope 对账发现")
    }

    // mediaId 形状：folder:<sourceId>:<opaqueItemId>，不含相对路径。
    func testMediaIdShape() async throws {
        try put("x.png")
        let batch = try await source.inScope(after: nil, limit: 10)
        let id = batch.first!.mediaId
        XCTAssertTrue(id.hasPrefix("folder:\(sourceId!):"))
        XCTAssertFalse(id.contains("x.png"), "mediaId 不含相对路径")
    }

    // sourceVersion = modifiedAtMs:size；captureAtMs 有修改时间填修改时间；元数据取不全 version 为空串（不可得）。
    func testVersionAndDetails() async throws {
        try put("v.jpg", content: "hello")
        let batch = try await source.inScope(after: nil, limit: 10)
        XCTAssertEqual(batch.count, 1)
        let snap = batch[0]
        let parts = snap.sourceVersion.split(separator: ":")
        XCTAssertEqual(parts.count, 2, "modifiedAtMs:size")
        XCTAssertEqual(snap.bucketId, "folder:\(sourceId!)")

        let details = try await source.lookup(snap.mediaId)
        XCTAssertEqual(details?.fileName, "v.jpg")
        XCTAssertEqual(details?.mimeType, "image/jpeg")
        XCTAssertEqual(details?.sizeBytes, 5)
        XCTAssertEqual(details?.captureAtMs, Int64(parts[0]) ?? 0, "captureAtMs = 修改时间")
    }

    // 授权失效口径：书签解析失败 / 根不可达 → SourceUnavailable，不能假报 0 项。
    func testUnresolvableBookmarkThrowsSourceUnavailable() async throws {
        var record = registry.record(id: sourceId)!
        record.bookmark = Data([0x01, 0x02, 0x03]) // 损坏书签
        registry.upsert(record)
        do {
            _ = try await source.inScope(after: nil, limit: 10)
            XCTFail("必须抛 SourceUnavailable")
        } catch is SourceUnavailable {
            // 期望路径
        } catch {
            XCTFail("错误类型不对：\(type(of: error))")
        }
        let existing = try await source.existingIds(["folder:\(sourceId!):whatever"])
        XCTAssertNil(existing, "枚举读不出来 = 不知道，不许当空集")
    }

    // 只有完整枚举成功后才判缺席：文件删除后再扫描，existingIds 反映缺席（不再在集合里）。
    func testExistingIdsReflectsCompleteEnumeration() async throws {
        try put("keep.jpg")
        try put("drop.jpg")
        let batch = try await source.inScope(after: nil, limit: 100)
        let dropId = try await idOf(rel: "drop.jpg")
        let keepId = try await idOf(rel: "keep.jpg")
        XCTAssertEqual(batch.count, 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("drop.jpg"))
        let existing = try await source.existingIds([dropId, keepId])
        XCTAssertEqual(existing, [keepId], "完整枚举成功，缺席 = 不在集合")
    }

    private func idOf(rel: String) async throws -> String {
        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: rel)
        return "folder:\(sourceId!):\(opaque)"
    }
}
