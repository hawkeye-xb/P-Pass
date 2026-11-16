// #1731 卡 2：FolderMediaSource 的合同测试（游标契约 / 过滤 / 版本 / 授权失效口径）。
import XCTest
import ImageIO
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

    private func put(_ rel: String, content: String = "data", modifiedAt: Date? = nil) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt { try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path) }
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
        XCTAssertEqual(ScopeKey.decode(snap.bucketId).albums, ["folder:\(sourceId!)"])
        XCTAssertNotNil(ScopeKey.decode(snap.bucketId).capturedAtMs)

        let details = try await source.lookup(snap.mediaId)
        XCTAssertEqual(details?.fileName, "v.jpg")
        XCTAssertEqual(details?.mimeType, "image/jpeg")
        XCTAssertEqual(details?.sizeBytes, 5)
        XCTAssertEqual(details?.captureAtMs, Int64(parts[0]) ?? 0, "captureAtMs = 修改时间")
    }

    // 分页按 mediaId 字节序（ADR §4.1）：全局升序、翻页无跳过。
    // 反证：按相对路径排序分页 → 路径顺序与随机 opaqueId 无关，第二页出现「id ≤ 游标」的条目 → 红。
    func testPaginationIsByMediaIdByteOrder() async throws {
        for n in 0..<12 { try put("file\(n).jpg", content: "c\(n)") }
        var collected: [String] = []
        var after: String? = nil
        while true {
            let page = try await source.inScope(after: after, limit: 5)
            if page.isEmpty { break }
            collected += page.map(\.mediaId)
            after = page.last!.mediaId
            if collected.count > 20 { XCTFail("分页打转"); break }
        }
        XCTAssertEqual(collected.count, 12, "翻页不漏（12 个全拿到）")
        for i in 1..<collected.count {
            XCTAssertTrue(MediaOrder.precedes(collected[i - 1], collected[i]), "全局严格升序")
        }
    }

    // 枚举中途失败：抛错（本轮「不知道」），映射不被污染（缺席不判源缺失）。
    // 反证：errorHandler 吞掉失败继续当完整枚举 → 子目录里的项被误判 source_missing → 红。
    func testEnumerationFailureMidWayKeepsMappingIntact() async throws {
        try put("before.jpg")
        let _ = try await source.inScope(after: nil, limit: 100)
        let beforeId = try await idOf(rel: "before.jpg")

        // 无权限子目录触发枚举错误（errorHandler 被叫 → failed → 抛错）。
        let secret = root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try "hidden".write(to: secret.appendingPathComponent("h.jpg"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secret.path) }

        do {
            _ = try await source.inScope(after: nil, limit: 100)
            XCTFail("中途失败必须抛（不能当完整枚举判缺席）")
        } catch {
            // FolderSourceError（中途失败）——不是假报 0 项
        }
        // 失败那轮没有对账：映射原样，before 的 id 不变。
        XCTAssertEqual(registry.relativePath(sourceId: sourceId, opaqueId: FolderMediaSource.opaqueId(of: beforeId, sourceId: sourceId)!), "before.jpg")
    }

    // alias 文件跳过（isAliasFileKey；symlink 同上）。
    func testAliasFilesAreSkipped() async throws {
        try put("real.jpg")
        // 造一个 Finder alias 形态的文件：bookmark 数据文件、带媒体扩展名。
        let aliasURL = root.appendingPathComponent("alias.jpg")
        let data = try root.appendingPathComponent("real.jpg").bookmarkData()
        try data.write(to: aliasURL)
        // alias 判定在实现里按文件头 "book" 字节签名；本地能造这种文件（bookmark 数据 + 媒体扩展名）。
        let batch = try await source.inScope(after: nil, limit: 100)
        XCTAssertEqual(batch.count, 1, "alias 文件跳过（按文件头签名识别）")
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

    // 文件夹与相册共用选中和时间过滤；没有拍摄元数据时才回退修改时间，子目录同规。
    // 反证：删除选中条件 → 取消勾选后仍有两项；删除时间条件 → old 也进入；只扫当前层 → nested 两项消失。
    func testSelectionAndModificationFallbackApplyRecursively() async throws {
        let start: Int64 = 1_800_000_000_000
        try put("nested/old.jpg", modifiedAt: Date(timeIntervalSince1970: Double(start) / 1000 - 1))
        try put("nested/new.mov", modifiedAt: Date(timeIntervalSince1970: Double(start) / 1000))
        let selected = FolderTestBox<Set<String>>(["folder:\(sourceId!)"])
        let since = FolderTestBox<BackupSince>(.since(ms: start))
        let sourceBucket = "folder:\(sourceId!)"
        let scoped = FolderMediaSource(registry: registry, sourceId: sourceId, directory: dir, logger: logger,
                                       scope: { (selected: selected.get(), known: [sourceBucket], since: since.get()) })
        var batch = try await scoped.inScope(after: nil, limit: 100)
        XCTAssertEqual(batch.count, 1, "起点之前的修改时间排除，起点当天包含")
        let key = try XCTUnwrap(batch.first).bucketId
        XCTAssertEqual(ScopeKey.decode(key).capturedAtMs, start)

        selected.set([])
        since.set(.all)
        batch = try await scoped.inScope(after: nil, limit: 100)
        XCTAssertTrue(batch.isEmpty, "取消勾选后即使全部时间也不返回该目录")
    }

    func testUncheckedFolderDoesNotEnumerateOrBlockPresence() async throws {
        var record = registry.record(id: sourceId)!
        record.bookmark = Data("broken".utf8)
        registry.upsert(record)
        let bucket = FolderMediaSource.bucketId(sourceId: sourceId)
        let scoped = FolderMediaSource(registry: registry, sourceId: sourceId, directory: dir, logger: logger,
                                       scope: { (selected: [], known: [bucket], since: .all) })
        let batch = try await scoped.inScope(after: nil, limit: 10)
        XCTAssertTrue(batch.isEmpty)
        let id = "folder:\(sourceId!):opaque"
        let present = try await scoped.existingIds([id])
        XCTAssertEqual(present, [id], "取消勾选的目录不做缺席判定，也不能因书签损坏拖住其他来源")
    }

    func testPendingFolderWaitsForSavedScopeBeforeFirstBackup() async throws {
        try put("pending.mov")
        var record = registry.record(id: sourceId)!
        record.status = FolderMediaSource.pendingScopeStatus
        XCTAssertTrue(registry.upsert(record))
        let bucket = FolderMediaSource.bucketId(sourceId: sourceId)
        let selected = FolderTestBox<Set<String>>([])
        let scoped = FolderMediaSource(registry: registry, sourceId: sourceId, directory: dir, logger: logger,
                                       scope: { (selected: selected.get(), known: [], since: .all) })
        var batch = try await scoped.inScope(after: nil, limit: 10)
        XCTAssertTrue(batch.isEmpty, "新目录只授权未保存时不能提前备份")
        selected.set([bucket])
        batch = try await scoped.inScope(after: nil, limit: 10)
        XCTAssertEqual(batch.count, 1, "保存范围后同一目录进入备份")
        XCTAssertEqual(registry.record(id: sourceId)?.status, "registered")
    }

    func testLegacyScopeKeepsRegisteredFolderActiveBeforeUnifiedSave() async throws {
        try put("legacy.mov")
        let scoped = FolderMediaSource(registry: registry, sourceId: sourceId, directory: dir, logger: logger,
                                       scope: { (selected: [], known: [], since: .all) })
        let batch = try await scoped.inScope(after: nil, limit: 10)
        XCTAssertEqual(batch.count, 1, "旧版没有文件夹勾选存值，不能让升级先悄悄停掉目录备份")
    }

    func testCaptureTimeAlwaysWinsOverModificationTime() {
        let start: Int64 = 1_700_000_000_000
        XCTAssertEqual(FolderMediaSource.effectiveCapturedAtMs(capturedAtMs: start, modifiedAtMs: start - 1_000), start)
        XCTAssertEqual(FolderMediaSource.effectiveCapturedAtMs(capturedAtMs: nil, modifiedAtMs: start), start)
        let capturedNew = FolderMediaSource.effectiveCapturedAtMs(capturedAtMs: start, modifiedAtMs: start - 1_000)
        XCTAssertTrue(ScopeKey.inTime(capturedAtMs: capturedNew, since: .since(ms: start)), "拍摄新、修改旧必须按拍摄时间纳入")
        let capturedOld = FolderMediaSource.effectiveCapturedAtMs(capturedAtMs: start - 1, modifiedAtMs: start + 1_000)
        XCTAssertFalse(ScopeKey.inTime(capturedAtMs: capturedOld, since: .since(ms: start)), "拍摄旧、今天修改仍排除")
    }

    func testExifDateTimeOriginalAndOffsetAreParsed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:16 10:00:00",
                "OffsetTimeOriginal": "+08:00",
            ],
        ]
        let ms = try XCTUnwrap(FolderMediaSource.imageCapturedAtMs(properties: properties, calendar: calendar))
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        XCTAssertEqual(date.timeIntervalSince1970, 1_794_794_400, accuracy: 0.001)
    }

    private func idOf(rel: String) async throws -> String {
        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: rel)
        return "folder:\(sourceId!):\(opaque)"
    }
}

private final class FolderTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
}
