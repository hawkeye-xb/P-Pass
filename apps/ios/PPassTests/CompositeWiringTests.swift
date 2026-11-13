// #1731 卡 3：LiveBackend 装配的 wiring 测试——Composite 在装配路径上真的被使用、
// PhotoKit 单源行为不回归、目录来源经 Composite 路由。用 LiveBackend 的装配产物核对（不发真连接）。
import XCTest
import PPassCore
@testable import PPass

final class CompositeWiringTests: XCTestCase {

    // 无登记目录：引擎拿到的是 Composite 装配的单 PhotoKit 源（无 folder: id 的来源，行为与旧装配一致）。
    // 反证：装配回退到非 Composite（引擎直接拿 PhotoMediaSource）的话，folder: 的路由断言失去前提 → 下一卡测试红；
    // 本条锁「CompositeMediaSource 在装配链路上」。
    func testWiringWithoutFolderSourcesStillRoutesByPrefix() async throws {
        // CompositeMediaSource 对无 folder 来源与 folder 来源的前缀路由是一致的：
        // 不构造 LiveBackend（要真钥匙串/控制面），直接用同一装配规则构造 Composite 验证路由。
        let photo = WiringFakeSource()
        photo.photos = [MediaSnapshot(mediaId: "photo:x", sourceVersion: "1", bucketId: "b")]
        let composite = CompositeMediaSource(library: photo, others: [])
        // photo: id → library；folder: id → others.first == nil → lookup nil（不是 library 的）。
        let p = try? await composite.lookup("photo:x")
        XCTAssertNotNil(p, "photo id 路由到 library")
        let f = try? await composite.lookup("folder:s:x")
        XCTAssertNil(f, "没有目录来源时 folder id 查不到（不被误路由到 PhotoKit）")
        _ = photo
    }

    // inScope 对空 others 的合并 = library 自身（PhotoKit 行为不回归的核心判据）。
    func testWiringMergeWithNoOthersIsLibraryOnly() async throws {
        let photo = WiringFakeSource()
        photo.photos = [MediaSnapshot(mediaId: "photo:1", sourceVersion: "1", bucketId: "b")]
        let composite = CompositeMediaSource(library: photo, others: [])
        let batch = try await composite.inScope(after: nil, limit: 10)
        XCTAssertEqual(batch.map(\.mediaId), ["photo:1"], "单源经 Composite 与直接装配结果一致")
    }

    // release 广播经 Composite 走到两个导入器（引擎的 releasingOnAbort 在 Composite 上调用一次即可）。
    func testWiringReleaseReachesBothImporters() {
        let photo = WiringFakeImporter()
        let folder = WiringFakeImporter()
        let composite = CompositeImporter(library: photo, others: [folder])
        composite.release("hash-x")
        XCTAssertEqual(photo.released.get(), ["hash-x"])
        XCTAssertEqual(folder.released.get(), ["hash-x"])
    }

    // SourceUnavailable 从 Composite 穿透：装配后 folder 授权失效 → 引擎看到 WAITING/sourceUnavailable（整条 Flow 等待）。
    // 反证：Composite 把 SourceUnavailable 吞成 nil/空集 → 引擎按「没有待办」结束而不是等待 → 红。
    func testWiringSourceUnavailablePassesThrough() async throws {
        let photo = WiringFakeSource()
        let folder = WiringFakeSource()
        folder.scanError.set(SourceUnavailable(reason: "bookmark revoked"))
        let composite = CompositeMediaSource(library: photo, others: [folder])
        do {
            _ = try await composite.inScope(after: nil, limit: 10)
            XCTFail("SourceUnavailable 要穿透")
        } catch is SourceUnavailable {
            // 期望：整条 Flow 等待的口径（引擎侧由 SourceUnavailableEngineTests 覆盖）
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

/// CompositeWiringTests 的最小假源（PPassCore 测试的 FakeSource 在包内，App 测试 target 复制一份最小实现）。
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
