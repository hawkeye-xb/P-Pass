// #1763 素材文件夹设置入口：可达性探测（列表「已授权 / 等待重新授权」的唯一依据）、演示端口、双语文案。
// 探测与端口契约：探测失败一律按「等待」显示，不误报可用（卡面验收场景最后一条）。
import XCTest
@testable import PPass

final class FolderSettingsTests: XCTestCase {
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
        engine.removeFolderSource(id: try XCTUnwrap(list.first?.id))
        XCTAssertEqual(engine.folderSourceCount(), 0)
        let after = await engine.folderSources()
        XCTAssertTrue(after.isEmpty)
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
}
