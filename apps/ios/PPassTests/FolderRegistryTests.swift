// #1731 卡 2：SourceRegistry 的合同测试。ADR「验收标准 E1/E2」Registry 条目；全部用本地临时目录。
import XCTest
@testable import PPass

final class FolderRegistryTests: XCTestCase {
    private var dir: URL!
    private var registry: FolderRegistry!
    private let logger = OSLogger()

    override func setUpWithError() throws {
        dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        registry = FolderRegistry(directory: dir, logger: logger)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFolder(name: String = "pics") throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)
        return url
    }

    // Registry 往返：登记 → id 稳定；重建实例（模拟重启）读盘恢复同一记录与映射。
    func testRoundTripSurvivesRecreate() throws {
        let url = try makeFolder()
        let id = try registry.addFolder(at: url, displayName: "pics")
        let opaque = registry.opaqueId(sourceId: id, relativePath: "sub/a.jpg")
        XCTAssertEqual(registry.relativePath(sourceId: id, opaqueId: opaque), "sub/a.jpg")

        let reloaded = FolderRegistry(directory: dir, logger: logger)
        XCTAssertEqual(reloaded.record(id: id)?.displayName, "pics")
        XCTAssertEqual(reloaded.relativePath(sourceId: id, opaqueId: opaque), "sub/a.jpg")
    }

    // 移除后 id 永不复用：登记新目录拿到的 id 不同于已移除的那个。
    func testRemovedIdsAreNeverReused() throws {
        let url = try makeFolder(name: "one")
        let first = try registry.addFolder(at: url, displayName: "one")
        registry.removeFolder(id: first)
        XCTAssertNil(registry.record(id: first))
        XCTAssertTrue(registry.isKnownOrRemoved(first), "墓碑保留")

        let second = try registry.addFolder(at: url, displayName: "again")
        XCTAssertNotEqual(second, first, "移除后不复用")
    }

    // 书签生成失败（对不存在的路径）→ 抛错、来源未启用，不假装登记成功。
    func testBookmarkFailureDoesNotEnableTheSource() throws {
        XCTAssertThrowsError(try registry.addFolder(at: dir.appendingPathComponent("nope-missing"), displayName: "ghost"))
        XCTAssertTrue(registry.allRecords().isEmpty, "不启用该来源")
    }

    // opaque id：同一路径稳定、跨重启稳定；不含相对路径（映射在 Registry 私有，mediaId 不带路径信息）。
    func testOpaqueIdIsStableAndHidesThePath() throws {
        let url = try makeFolder(name: "pics")
        let id = try registry.addFolder(at: url, displayName: "pics")
        let a1 = registry.opaqueId(sourceId: id, relativePath: "deep/nested/a.jpg")
        let a2 = registry.opaqueId(sourceId: id, relativePath: "deep/nested/a.jpg")
        XCTAssertEqual(a1, a2)
        XCTAssertFalse(a1.contains("/"), "opaqueId 不含相对路径")
        XCTAssertFalse(a1.contains("a.jpg"))

        let reloaded = FolderRegistry(directory: dir, logger: logger)
        XCTAssertEqual(reloaded.opaqueId(sourceId: id, relativePath: "deep/nested/a.jpg"), a1, "跨重启稳定")
    }

    // 相对路径规范化：拒绝对路径与 ..；`.` 段折叠；分隔符统一。
    func testPathNormalization() throws {
        XCTAssertEqual(try FolderPaths.normalize("a/b.jpg"), "a/b.jpg")
        XCTAssertEqual(try FolderPaths.normalize("./a/./b.jpg"), "a/b.jpg")
        XCTAssertEqual(try FolderPaths.normalize("a//b.jpg"), "a/b.jpg")
        XCTAssertThrowsError(try FolderPaths.normalize("/abs/a.jpg"))
        XCTAssertThrowsError(try FolderPaths.normalize("a/../b.jpg"))
        XCTAssertThrowsError(try FolderPaths.normalize(".."))
    }

    // Unicode 不折叠：NFD 与预组合是两条路径、两个 opaque id（判等按原始 UTF-8 字节）。
    func testUnicodeIsNotFolded() throws {
        let combining = "cafe\u{0301}.jpg"
        let precomposed = "caf\u{00E9}.jpg"
        XCTAssertNotEqual(Array(nfcBytes(combining)), Array(nfcBytes(precomposed)))
        let url = try makeFolder(name: "uni")
        let id = try registry.addFolder(at: url, displayName: "uni")
        let o1 = registry.opaqueId(sourceId: id, relativePath: combining)
        let o2 = registry.opaqueId(sourceId: id, relativePath: precomposed)
        XCTAssertNotEqual(o1, o2, "不同字节序 → 不同 id，不得合并两个文件")
    }

    private func nfcBytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // 完整枚举对账：新路径分配 id；缺席路径返回缺席集合（调用方据完整枚举判源缺失）。
    func testReconcileAssignsNewAndReportsMissing() throws {
        let url = try makeFolder(name: "rec")
        let id = try registry.addFolder(at: url, displayName: "rec")
        let a = registry.opaqueId(sourceId: id, relativePath: "a.jpg")
        let b = registry.opaqueId(sourceId: id, relativePath: "b.jpg")
        let missing = try registry.reconcile(sourceId: id, observedPaths: ["a.jpg", "c.jpg"])
        XCTAssertEqual(missing, [b], "完整枚举没看到的按源缺失上报")
        XCTAssertEqual(registry.relativePath(sourceId: id, opaqueId: a), "a.jpg")
        XCTAssertNotNil(registry.relativePath(sourceId: id, opaqueId: registry.opaqueId(sourceId: id, relativePath: "c.jpg")))
    }

    // 完整枚举为空 = 全部源缺失（只在完整枚举成功时调用）。
    func testReconcileWithEmptyObservationReportsEverythingMissing() throws {
        let url = try makeFolder(name: "empty")
        let id = try registry.addFolder(at: url, displayName: "empty")
        _ = registry.opaqueId(sourceId: id, relativePath: "gone.jpg")
        let missing = try registry.reconcile(sourceId: id, observedPaths: [])
        XCTAssertEqual(missing.count, 1)
    }

    // stale 书签：stale = true 且根仍可用 → 重建（freshBookmark）并原子替换、状态回 registered。
    // 判红设计：同一 URL 的 bookmarkData 可能逐字节相同，直接断言 NotEqual 判不了「重建发生了」——
    // 用注入的 freshBookmark 产一份不同的数据；反证：删掉整个重建分支 → 落盘的还是旧书签 ≠ 注入数据 → 红。
    func testStaleBookmarkIsRebuiltAndReplacedAtomically() throws {
        let url = try makeFolder(name: "stale")
        let id = try registry.addFolder(at: url, displayName: "stale")
        let record = registry.record(id: id)!
        let injected = Data("fresh-bookmark-bytes".utf8)
        FolderBookmarks.freshBookmark = { _ in injected }
        defer { FolderBookmarks.freshBookmark = { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) } }
        XCTAssertNotEqual(injected, record.bookmark)

        let root = try FolderBookmarks.resolve(record, registry: registry, logger: logger, forceStale: true)
        XCTAssertEqual(root.record.bookmark, injected, "重建分支用了新生成的书签")
        XCTAssertEqual(root.record.status, "registered")
        XCTAssertEqual(registry.record(id: id)?.bookmark, injected, "替换落了盘（内存与持久层一致）")
        // 「真的落盘」：用同一目录新建实例读回（内存改了没写盘的话这里是旧书签）。
        let reloaded = FolderRegistry(directory: dir, logger: logger)
        XCTAssertEqual(reloaded.record(id: id)?.bookmark, injected, "持久层里是重建后的书签")
    }

    // 重建成功但落盘失败 → 不宣称已注册（状态回 recoveryUnverified，与返回记录一致）。
    // 反证：忽略 upsert 结果直接打 registered → status 与持久层不一致 → 红。
    func testRebuildOkButPersistFailedMarksUnverified() throws {
        let url = try makeFolder(name: "persistfail")
        let id = try registry.addFolder(at: url, displayName: "persistfail")
        let record = registry.record(id: id)!
        let injected = Data("fresh-but-unsaved".utf8)
        FolderBookmarks.freshBookmark = { _ in injected }
        defer { FolderBookmarks.freshBookmark = { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) } }
        // 让持久层写失败：把目录换成只读父目录下的新 registry（与 addFolder 失败用例同一构造）。
        let parent = dir.appendingPathComponent("locked2", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let locked = FolderRegistry(directory: parent.appendingPathComponent("reg"), logger: logger)
        locked.upsert(record)
        let root = try FolderBookmarks.resolve(record, registry: locked, logger: logger, forceStale: true)
        XCTAssertEqual(root.record.status, "recoveryUnverified", "落盘失败不宣称已注册")
        // 内存里被改成新书记录前先撤销：resolve 落盘失败不应把 locked 的内存置成 registered。
        XCTAssertEqual(locked.record(id: id)?.status, "recoveryUnverified", "内存状态与返回一致")
    }

    // 替换失败口径：stale 且根不可用（或重建抛 nil）→ 旧书签保留、状态记 recoveryUnverified。
    // 反证：删掉 else 分支（不写 recoveryUnverified）→ status 保持 registered → 红。
    func testStaleRebuildFailureKeepsOldBookmarkAndMarksUnverified() throws {
        let url = try makeFolder(name: "stalefail")
        let id = try registry.addFolder(at: url, displayName: "stalefail")
        let record = registry.record(id: id)!
        FolderBookmarks.freshBookmark = { _ in nil } // 重建失败（盘未挂载/授权被撤的替身）
        defer { FolderBookmarks.freshBookmark = { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) } }

        let root = try FolderBookmarks.resolve(record, registry: registry, logger: logger, forceStale: true)
        XCTAssertEqual(root.record.status, "recoveryUnverified")
        XCTAssertEqual(root.record.bookmark, record.bookmark, "旧书签保留（没被毁掉）")
        XCTAssertEqual(registry.record(id: id)?.status, "recoveryUnverified")
    }

    // 损坏书签：resolve 抛错、旧记录原样保留。

    // 非 stale：resolve 不动书签、不动状态。
    func testResolveWithoutStaleKeepsEverything() throws {
        let url = try makeFolder(name: "fresh")
        let id = try registry.addFolder(at: url, displayName: "fresh")
        let record = registry.record(id: id)!
        let root = try FolderBookmarks.resolve(record, registry: registry, logger: logger)
        XCTAssertEqual(root.record.bookmark, record.bookmark)
        XCTAssertEqual(root.record.status, "registered")
    }

    // 损坏书签：resolve 抛错、旧记录原样保留。
    func testUnreadableBookmarkThrowsAndKeepsRecord() throws {
        let url = try makeFolder(name: "vanish")
        let id = try registry.addFolder(at: url, displayName: "vanish")
        var record = registry.record(id: id)!
        record.bookmark = Data([0x09]) // 损坏 → resolve 直接抛
        registry.upsert(record)
        let before = registry.record(id: id)
        XCTAssertThrowsError(try FolderBookmarks.resolve(registry.record(id: id)!, registry: registry, logger: logger))
        XCTAssertEqual(registry.record(id: id), before, "失败不动旧记录")
        _ = url
    }

    // 书签写盘失败：addFolder 抛错、来源未启用（ADR「不假装登记成功」）。
    // 反证：吞掉写失败直接返回 id → 来源在内存里活着、重启后凭空消失 → 红线上的事故；测试用只读目录锁住这条。
    func testPersistFailureDoesNotRegisterTheSource() throws {
        let readOnly = dir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        _ = readOnly
        // 用「父目录设为只读」让 registry 写盘失败。
        let parent = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let inner = parent.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try "x".write(to: inner.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path) // r-x：写不进
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let locked = FolderRegistry(directory: parent.appendingPathComponent("registry"), logger: logger)
        XCTAssertThrowsError(try locked.addFolder(at: inner, displayName: "locked")) { error in
            guard let e = error as? FolderSourceError else { return XCTFail("错误类型不对：\(type(of: error))") }
            XCTAssertEqual(e.reason, "bookmark save failed")
        }
        XCTAssertTrue(locked.allRecords().isEmpty, "来源未启用")
    }
}
