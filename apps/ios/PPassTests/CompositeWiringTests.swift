// #1731 卡 3：LiveBackend 装配的 wiring 测试——统一经 Composite（无目录也走 Composite，ADR §1「不另做实施分支」）、
// 按全部 folderSources 装配多来源、folder:<sourceId> 按 mediaId 里的 sourceId 精确路由、inScope 对 folder: 绕过 since。
// 用装配函数本体核对：LiveBackend 引擎拿到的 media / importer / inScope 就是 assembleMedia / engineInScope 的产物，
// 不构造 LiveBackend（要真钥匙串 / 控制面）；装配件用与 FolderImporterTests 相同的本地临时目录 + 真 NativeProvider。
import XCTest
import PPassCore
@testable import PPass

final class CompositeWiringTests: XCTestCase {
    private var dir: URL!
    private var registry: FolderRegistry!
    private var native: NativeProvider!
    private let logger = OSLogger()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiring-\(UUID().uuidString)")
        registry = FolderRegistry(directory: dir, logger: logger)
        native = try NativeProvider(root: dir)
    }

    override func tearDownWithError() throws {
        native?.ffi.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    /// 登记一个真实目录（含一个文件），返回 sourceId。
    private func addFolder(_ name: String, file: String = "a.jpg") throws -> String {
        let root = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "data".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return try registry.addFolder(at: root, displayName: name)
    }

    /// 与 LiveBackend.init 同一装配路径：photoSource 用假源（不碰 PhotoKit），其余全是真装配产物。
    private func assemble(folderSources: [FolderRecord]) throws -> (media: MediaSource, importer: MediaImporter) {
        let photo = WiringFakeSource()
        photo.photos = [MediaSnapshot(mediaId: "photo:x", sourceVersion: "1", bucketId: "b")]
        return try LiveBackend.assembleMedia(folderSources: folderSources, registry: registry, directory: dir,
                                             photoSource: photo, photoImporter: WiringFakeImporter(),
                                             provider: native!, logger: logger)
    }

    // 统一经 Composite（ADR §1「不另做实施分支」）：无登记目录也是 Composite 装配（不是裸 PhotoMediaSource）。
    // 反证：装配回退成「空目录直接返回 PhotoMediaSource」→ 断言红。
    func testAssemblyWithoutFolderSourcesStillUsesComposite() throws {
        let assembled = try assemble(folderSources: [])
        XCTAssertTrue(assembled.media is CompositeMediaSource, "无目录也要经 Composite（不另做实施分支）")
        XCTAssertTrue(assembled.importer is CompositeImporter, "无目录也要经 CompositeImporter")
    }

    // 无目录分支行为与直接装配一致：photo id 走 library；folder id 查不到（不误路由到 PhotoKit）。
    func testAssemblyWithoutFolderSourcesBehavesLikeLibrary() async throws {
        let assembled = try assemble(folderSources: [])
        let p = try await assembled.media.lookup("photo:x")
        XCTAssertEqual(p?.snapshot.mediaId, "photo:x", "photo id 路由到 library")
        let f = try await assembled.media.lookup("folder:s:x")
        XCTAssertNil(f, "没有目录来源时 folder id 查不到（不被误路由到 PhotoKit）")
        let batch = try await assembled.media.inScope(after: nil, limit: 10)
        XCTAssertEqual(batch.map(\.mediaId), ["photo:x"], "单源经 Composite 与直接装配结果一致")
    }

    // 有登记目录 = 按全部 folderSources 逐个装配；folder:<sourceId> 按 mediaId 里的 sourceId 精确路由。
    // 反证：只装第一个来源（folderSources[0]）或全部 folder id 路由到 others.first → 第二个来源的 id 查不到 → 红。
    func testAssemblyRoutesEveryFolderSourceBySourceId() async throws {
        let s1 = try addFolder("lib-one")
        let s2 = try addFolder("lib-two")
        let assembled = try assemble(folderSources: registry.allRecords())
        let batch = try await assembled.media.inScope(after: nil, limit: 10)
        let ids = batch.map(\.mediaId)
        let id1 = try XCTUnwrap(ids.first { $0.hasPrefix("folder:\(s1):") }, "来源 1 的 id 要出现在装配扫描里")
        let id2 = try XCTUnwrap(ids.first { $0.hasPrefix("folder:\(s2):") }, "来源 2 的 id 要出现在装配扫描里（全部来源都装配）")
        // 精确路由：id 只会被自己的来源答出（目录来源对别人前缀的 id 返回 nil），bucketId 带自己的 sourceId。
        let d1 = try await assembled.media.lookup(id1)
        XCTAssertEqual(try XCTUnwrap(d1).snapshot.bucketId, "folder:\(s1)", "folder:\(s1) 的 id 要路由到来源 1")
        let d2 = try await assembled.media.lookup(id2)
        XCTAssertEqual(try XCTUnwrap(d2).snapshot.bucketId, "folder:\(s2)", "folder:\(s2) 的 id 要路由到来源 2")
        // 装配里没有的 sourceId：路由不到（不误落 library，也不误落到别的目录来源）。
        let unknown = try await assembled.media.lookup("folder:gone:z")
        XCTAssertNil(unknown)
    }

    // inScope（装配注入三处之一）：folder: 绕过共享 since（ADR §4）；PhotoKit 走现有 ScopeKey 判定。
    // 反证：去掉 folder: 豁免 → folder bucket 按相册判定，selected 为空判 false → 第一条红。
    func testEngineInScopeBypassesSinceForFolder() {
        XCTAssertTrue(LiveBackend.engineInScope("folder:\(UUID().uuidString)", selected: [], since: .since(ms: 123)),
                      "folder: 绕过共享 since（目录来源不看 PhotoKit 时间档）")
        XCTAssertFalse(LiveBackend.engineInScope("album-x", selected: [], since: .all), "PhotoKit 未选中的相册不在范围内")
        XCTAssertTrue(LiveBackend.engineInScope("album-x", selected: ["album-x"], since: .all), "PhotoKit 选中的相册在范围内")
    }

    // release 广播经 Composite 走到全部导入器且幂等（装配口径：广播，不按 hash 推断来源）。
    func testWiringReleaseReachesAllImporters() {
        let photo = WiringFakeImporter()
        let folder = WiringFakeImporter()
        let composite = CompositeImporter(library: photo, others: [folder])
        composite.release("hash-x")
        composite.release("hash-x")
        XCTAssertEqual(photo.released.get(), ["hash-x", "hash-x"], "广播且幂等：两次调用两次送达")
        XCTAssertEqual(folder.released.get(), ["hash-x", "hash-x"], "广播且幂等：两次调用两次送达")
    }

    // SourceUnavailable 从装配产物穿透：整条 Flow 等待的口径（引擎侧由 SourceUnavailableEngineTests 覆盖）。
    // 触发用 ADR 异常口径第一行「书签不存在、损坏」：确定性，不依赖模拟器对已删目标的解析行为。
    // 反证：装配层把它吞成 nil / 空集 → 引擎按「没有待办」结束而不是等待 → 红。
    func testWiringSourceUnavailablePassesThrough() async throws {
        let s = try addFolder("gone")
        var record = try XCTUnwrap(registry.record(id: s), "登记的来源要能读到")
        record.bookmark = Data("not-a-bookmark".utf8)
        registry.upsert(record)
        let assembled = try assemble(folderSources: registry.allRecords())
        do {
            _ = try await assembled.media.inScope(after: nil, limit: 10)
            XCTFail("SourceUnavailable 要穿透")
        } catch is SourceUnavailable {
            // 期望
        } catch {
            XCTFail("错误类型不对：\(type(of: error))")
        }
    }
}

/// 测试用的锁盒子（LockedBox 是 PPassCore internal，App 测试 target 复制一份最小实现）。
private final class WiringBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func update<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// CompositeWiringTests 的最小假源（PhotoKit 侧不进本测试；目录来源走真 FolderMediaSource）。
private final class WiringFakeSource: MediaSource, @unchecked Sendable {
    var photos: [MediaSnapshot] = []
    let scanError = WiringBox<Error?>(nil)
    let lock = NSLock()

    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        if let e = scanError.get() { throw e }
        lock.lock(); defer { lock.unlock() }
        return Array(photos.filter { snap in after.map { MediaOrder.precedes($0, snap.mediaId) } ?? true }.prefix(limit))
    }

    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] { [] }
    func currentPosition() async throws -> DiscoveryPosition { DiscoveryPosition(raw: Data("wiring".utf8)) }
    func libraryIdentity() async throws -> String? { "wiring-lib" }

    func lookup(_ mediaId: String) async throws -> MediaDetails? {
        lock.lock(); defer { lock.unlock() }
        guard photos.contains(where: { MediaOrder.same($0.mediaId, mediaId) }) else { return nil }
        return MediaDetails(snapshot: MediaSnapshot(mediaId: mediaId, sourceVersion: "1", bucketId: "b"), fileName: "f", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)
    }

    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return Set(mediaIds.filter { id in photos.contains { MediaOrder.same($0.mediaId, id) } })
    }

    var preciseDiscovery: Bool { true }
}

private final class WiringFakeImporter: MediaImporter, @unchecked Sendable {
    let released = WiringBox<[String]>([])
    func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
        .imported(contentHash: "hash", sizeBytes: 1)
    }
    func importPicked(_ item: PickedItem) async throws -> ImportResult { throw PickedImportUnsupported() }
    func release(_ contentHash: String) { released.update { $0.append(contentHash) } }
}
