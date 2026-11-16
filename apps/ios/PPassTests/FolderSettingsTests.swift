// #1763 素材文件夹设置入口：可达性探测（列表「已授权 / 等待重新授权」的唯一依据）、演示端口、双语文案、
// refreshFolderSources 的复用与退役决策。探测失败一律按「等待」显示，不误报可用（卡面验收场景最后一条）。
import XCTest
@testable import PPass

final class FolderSettingsTests: XCTestCase {
    private var dir: URL!
    private var registry: FolderRegistry!
    private var native: NativeProvider!
    private let logger = OSLogger()

    override func setUpWithError() throws {
        dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        registry = FolderRegistry(directory: dir, logger: logger)
        native = try NativeProvider(root: dir)
    }

    override func tearDownWithError() throws {
        native?.ffi.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFolder(name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)
        return url
    }

    // 探测：目录在 → true（App 私有普通目录，start=false 也能走到 fileExists）。
    // 反证：把探测写成恒 true（不解析书签）→ 书签损坏的记录也报「已授权」→ 第二条红。
    func testProbeReportsReachableDirectory() async throws {
        let url = try makeFolder(name: "reachable")
        let id = try registry.addFolder(at: url, displayName: "reachable")
        let record = try XCTUnwrap(registry.record(id: id))
        let available = await LiveBackend.folderSourceAvailable(record: record, registry: registry, logger: logger)
        XCTAssertTrue(available, "在的目录探测为可用")
    }

    // 探测：书签损坏（确定性触发，同 CompositeWiringTests 的口径）→ false = 等待重新授权，不误报。
    func testProbeReportsBrokenBookmarkAsUnavailable() async throws {
        let url = try makeFolder(name: "broken")
        let id = try registry.addFolder(at: url, displayName: "broken")
        var record = try XCTUnwrap(registry.record(id: id))
        record.bookmark = Data("not-a-bookmark".utf8)
        registry.upsert(record)
        let available = await LiveBackend.folderSourceAvailable(record: record, registry: registry, logger: logger)
        XCTAssertFalse(available, "书签损坏 = 等待重新授权")
    }

    // 探测：登记后目录被删（根不可达）→ false，不误报可用（卡面「目录不可达按 SourceUnavailable 等待」的列表侧口径）。
    func testProbeReportsMissingRootAsUnavailable() async throws {
        let url = try makeFolder(name: "vanishes")
        let id = try registry.addFolder(at: url, displayName: "vanishes")
        let record = try XCTUnwrap(registry.record(id: id))
        try FileManager.default.removeItem(at: url)
        let available = await LiveBackend.folderSourceAvailable(record: record, registry: registry, logger: logger)
        XCTAssertFalse(available, "根目录没了 = 等待重新授权")
    }

    // 演示端口：添加 / 列表 / 计数 / 移除在同一份内存上自洽（界面壳与截图用，不走真注册表）。
    func testFakeEngineFolderOpsRoundTrip() async throws {
        let engine = FakeEngine(scenario: .normal, media: FakeMediaLibrary(scenario: .normal))
        XCTAssertEqual(engine.folderSourceCount(), 0)
        try await engine.addFolderSource(at: URL(fileURLWithPath: "/demo/folder"), displayName: "Demo")
        let list = await engine.folderSources()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.displayName, "Demo")
        XCTAssertEqual(list.first?.available, true, "演示数据一律显示可用")
        XCTAssertEqual(engine.folderSourceCount(), 1)
        try engine.removeFolderSource(id: XCTUnwrap(list.first?.id))
        XCTAssertEqual(engine.folderSourceCount(), 0)
        let after = await engine.folderSources()
        XCTAssertTrue(after.isEmpty)
    }

    // 设置行值分支（0 = 未添加 / 1 = 单数键 / N = 复数键）有测试可判红（#1763 评审建议3：
    // 删掉任一分支这里就红）。对照双语言表逐一断言，改错键名或删分支都跑不掉。
    func testFolderRowValueMapsCountsToKeys() throws {
        XCTAssertEqual(SettingsScreen.folderValue(count: 0),
                       Bundle.main.localizedString(forKey: "folder_sources_none", value: "\u{1}", table: "IOS"))
        XCTAssertEqual(SettingsScreen.folderValue(count: 1),
                       Bundle.main.localizedString(forKey: "folder_sources_count_one", value: "\u{1}", table: "IOS"))
        XCTAssertEqual(SettingsScreen.folderValue(count: 3),
                       String(format: Bundle.main.localizedString(forKey: "folder_sources_count_many", value: "\u{1}", table: "IOS"), 3))
        XCTAssertNotEqual(SettingsScreen.folderValue(count: 0), SettingsScreen.folderValue(count: 1))
        XCTAssertNotEqual(SettingsScreen.folderValue(count: 1), SettingsScreen.folderValue(count: 3))
    }

    // 文案：两语言齐全（缺失时 L.s 会 assertionFailure，这里显式把新键都核一遍）。
    func testFolderStringsPresentInBothLanguages() throws {
        let keys = ["folder_sources_row", "folder_sources_title", "folder_sources_add", "folder_sources_empty_body",
                    "folder_sources_none", "folder_sources_count_one", "folder_sources_count_many",
                    "folder_sources_status_ok", "folder_sources_status_wait",
                    "folder_sources_reauth", "folder_sources_remove", "folder_sources_remove_confirm_title",
                    "folder_sources_remove_confirm_body", "folder_sources_footer", "folder_sources_add_failed"]
        for lang in ["zh-Hans", "en"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"), "缺 \(lang).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{1}", table: "IOS")
                XCTAssertNotEqual(value, "\u{1}", "\(lang) 缺文案 key：\(key)")
            }
        }
    }

    // MARK: refreshFolderSources 的复用与退役（#1763 评审建议1 判红）

    // 注册表里还在的 id 复用原实例（=== 同一实例——整体重建会在换集合瞬间放掉仍在供数期的根授权，
    // 别处目录正在供数的大文件会因此失败）；注册表里消失的 id 进 dropped 且不再在装配集合里。
    // 反证：refresh 全部重建（不复用）→ A 的断言红；退役漏放 dropped → B 的断言红。
    func testMergedFolderPartsReusesKeptAndDropsRemoved() throws {
        let dirA = try makeFolder(name: "reuse-a")
        let idA = try registry.addFolder(at: dirA, displayName: "a")
        let dirB = try makeFolder(name: "reuse-b")
        let idB = try registry.addFolder(at: dirB, displayName: "b")
        let dirC = try makeFolder(name: "reuse-c")
        let idC = try registry.addFolder(at: dirC, displayName: "c")
        let prior: [String: (source: FolderMediaSource, importer: FolderImporter)] = [
            idA: (FolderMediaSource(registry: registry, sourceId: idA, directory: dir, logger: logger),
                  FolderImporter(registry: registry, sourceId: idA, directory: dir, provider: native!, logger: logger)),
            idB: (FolderMediaSource(registry: registry, sourceId: idB, directory: dir, logger: logger),
                  FolderImporter(registry: registry, sourceId: idB, directory: dir, provider: native!, logger: logger)),
        ]
        // 场景：B 已从注册表移除（refreshFolderSources 由注册表现值驱动）→ records = A、C。
        try registry.removeFolder(id: idB)
        let records = registry.allRecords()
        let fresh = LiveBackend.folderParts(records: records, registry: registry, directory: dir, provider: native!, logger: logger)
        let merged = LiveBackend.mergedFolderParts(records: records, fresh: fresh, prior: prior)
        XCTAssertTrue(merged.sources.contains { $0 === prior[idA]!.source }, "A 复用原来源实例")
        XCTAssertTrue(merged.importers.contains { $0 === prior[idA]!.importer }, "A 复用原导入器实例")
        XCTAssertTrue(merged.dropped.contains { $0 === prior[idB]!.importer }, "注册表里消失的 B 进 dropped（退役释放）")
        XCTAssertFalse(merged.sources.contains { $0 === prior[idB]!.source }, "B 不再在装配集合里")
        let newC = merged.importers.first { $0.folderSourceId == idC }
        XCTAssertNotNil(newC, "新来源 C 用新实例")
        XCTAssertFalse(merged.dropped.contains { $0 === newC }, "新来源不误进 dropped")
        XCTAssertEqual(merged.sources.count, records.count, "集合形状与注册表一致")
    }

    // releaseHeld 幂等且可重复调用（退役与 deinit 双路径都要安全）；空持有时调用也无害。
    func testReleaseHeldIsIdempotent() throws {
        let dirA = try makeFolder(name: "release-me")
        let idA = try registry.addFolder(at: dirA, displayName: "a")
        let importer = FolderImporter(registry: registry, sourceId: idA, directory: dir, provider: native!, logger: logger)
        importer.releaseHeld()
        importer.releaseHeld()
        importer.release("no-such-hash")
    }
}
