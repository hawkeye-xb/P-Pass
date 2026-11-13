// #1731 卡 3：Composite 的合同测试（卡 1 钉死的 presence 契约在此落地）。
// 反证说明在每条注释；用 test double 直接构造「一个来源不可信」的场景。
import XCTest
@testable import PPassCore

final class CompositeSourceTests: XCTestCase {

    // MARK: doubles

    /// 可配置的假来源：existingIds 返回（nil = 不知道）、inScope 抛错可注入。
    private final class FakeSource: MediaSource, FolderSourceIdentifying, @unchecked Sendable {
        let folderSourceId: String
        let id: String
        let existing: Locked<Set<String>?>
        let scanError = Locked<Error?>(nil)
        let lookupError = Locked<Error?>(nil)
        private(set) var photos: [MediaSnapshot] = []
        let precise = Locked(true)

        init(id: String, existing: Set<String>? = [], photos: [MediaSnapshot] = []) {
            self.id = id
            self.folderSourceId = id
            self.existing = Locked(existing)
            self.photos = photos
        }

        func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
            if let e = scanError.get() { throw e }
            return photos.filter { snap in after.map { MediaOrder.precedes($0, snap.mediaId) } ?? true }
                .prefix(limit).map { $0 }
        }

        func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] { [] }
        func currentPosition() async throws -> DiscoveryPosition { DiscoveryPosition(raw: Data("pos-\(id)".utf8)) }
        func libraryIdentity() async throws -> String? { id == "lib" ? "lib-1" : nil }

        func lookup(_ mediaId: String) async throws -> MediaDetails? {
            if let e = lookupError.get() { throw e }
            guard photos.contains(where: { MediaOrder.same($0.mediaId, mediaId) }) else { return nil }
            return MediaDetails(snapshot: MediaSnapshot(mediaId: mediaId, sourceVersion: "1", bucketId: "b"), fileName: "f", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)
        }

        func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
            existing.get().map { present in Set(mediaIds.filter { present.contains($0) }) }
        }

        var preciseDiscovery: Bool { precise.get() }
    }

    /// 可配置的假导入器：记录 release 广播。
    private final class FakeImporter: MediaImporter, FolderImportIdentifying, @unchecked Sendable {
        let folderSourceId: String
        let released: Locked<[String]>
        let results: Locked<[String: ImportResult]>

        init(folderSourceId: String) {
            self.folderSourceId = folderSourceId
            self.released = Locked([])
            self.results = Locked([:])
        }

        func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
            if let r = results.get()[details.snapshot.mediaId] { return r }
            return .imported(contentHash: "hash-" + details.snapshot.mediaId, sizeBytes: 1)
        }

        func importPicked(_ item: PickedItem) async throws -> ImportResult { throw PickedImportUnsupported() }

        func release(_ contentHash: String) {
            released.update { $0.append(contentHash) }
        }
    }

    private func snap(_ id: String) -> MediaSnapshot {
        MediaSnapshot(mediaId: id, sourceVersion: "1", bucketId: "b")
    }

    // MARK: presence 合并（卡 1 钉死的契约）

    // 任一来源不可信（nil）→ 整体 nil。
    // 反证：返回部分并集（把 nil 当空集继续归并）→ 返回了非 nil → 红。
    func testPresenceNilFromAnySourceMakesWholeNil() async throws {
        let photo = FakeSource(id: "lib", existing: ["photo:1"])
        let folder = FakeSource(id: "folder-s1", existing: nil)
        let composite = CompositeMediaSource(library: photo, others: [folder])
        let result = try await composite.existingIds(["photo:1", "folder:folder-s1:x"])
        XCTAssertNil(result, "任一来源不可信 → 整体 nil（不部分并集）")
    }

    // 两个来源都可信 → 各自结果合并（不是 nil、不是空集）。
    func testPresenceMergesWhenAllTrusted() async throws {
        let photo = FakeSource(id: "lib", existing: ["photo:1"])
        let folder = FakeSource(id: "folder-s1", existing: ["folder:folder-s1:x"])
        let composite = CompositeMediaSource(library: photo, others: [folder])
        let result = try await composite.existingIds(["photo:1", "folder:folder-s1:x"])
        XCTAssertEqual(result, ["photo:1", "folder:folder-s1:x"])
    }

    // 多目录来源：existingIds 按 mediaId 里的 sourceId 分组路由，各来源只答自己的 id。
    // 反证：把全部 folder id 发给第一个来源（others.first）→ 第二个来源的 id 查不到 → 红。
    func testPresenceRoutesEachFolderSourceBySourceId() async throws {
        let photo = FakeSource(id: "lib", existing: ["photo:1"])
        let s1 = FakeSource(id: "s1", existing: ["folder:s1:x"])
        let s2 = FakeSource(id: "s2", existing: ["folder:s2:y"])
        let composite = CompositeMediaSource(library: photo, others: [s1, s2])
        let result = try await composite.existingIds(["photo:1", "folder:s1:x", "folder:s2:y", "folder:gone:z"])
        XCTAssertEqual(result, ["photo:1", "folder:s1:x", "folder:s2:y"],
                       "各来源只答自己的 id；装配里没有的 sourceId 视作缺席")
    }

    // folder 来源抛 SourceUnavailable → 原样上抛（整条 Flow 等待的口径）。
    func testSourceUnavailablePropagates() async throws {
        let photo = FakeSource(id: "lib", existing: ["photo:1"])
        let folder = FakeSource(id: "folder-s1", existing: ["folder:folder-s1:x"])
        folder.scanError.set(SourceUnavailable(reason: "bookmark revoked"))
        let composite = CompositeMediaSource(library: photo, others: [folder])
        do {
            _ = try await composite.inScope(after: nil, limit: 10)
            XCTFail("要抛 SourceUnavailable")
        } catch is SourceUnavailable {
            // 期望
        } catch {
            XCTFail("错误类型不对：\(type(of: error))")
        }
    }

    // MARK: 快照合并与路由

    // inScope 合并两个来源并按 mediaId 字节序全局排序。
    func testInScopeMergesAndSortsByMediaId() async throws {
        let photo = FakeSource(id: "lib", photos: [snap("photo:2"), snap("photo:1")])
        let folder = FakeSource(id: "folder-s1", photos: [snap("folder:folder-s1:b"), snap("folder:folder-s1:a")])
        let composite = CompositeMediaSource(library: photo, others: [folder])
        let batch = try await composite.inScope(after: nil, limit: 10)
        XCTAssertEqual(batch.map(\.mediaId), [
            "folder:folder-s1:a", "folder:folder-s1:b", "photo:1", "photo:2",
        ], "folder: 前缀字节序在 photo: 之前（f < p）")
    }

    // lookup 按前缀路由；PhotoKit 的 id 不落 folder，folder 的 id 不落 PhotoKit。
    func testLookupRoutesByPrefix() async throws {
        let photo = FakeSource(id: "lib", photos: [snap("photo:1")])
        let folder = FakeSource(id: "folder-s1", photos: [snap("folder:folder-s1:x")])
        let composite = CompositeMediaSource(library: photo, others: [folder])
        let p = try await composite.lookup("photo:1")
        XCTAssertEqual(p?.snapshot.mediaId, "photo:1")
        let f = try await composite.lookup("folder:folder-s1:x")
        XCTAssertEqual(f?.snapshot.mediaId, "folder:folder-s1:x")
        let pMissing = try await composite.lookup("photo:999")
        XCTAssertNil(pMissing)
        let fMissing = try await composite.lookup("folder:folder-s1:missing")
        XCTAssertNil(fMissing)
    }

    // folder id 的 sourceId 在装配里没有 → 路由不到（不误落 library，也不误落到别的目录来源）。
    func testLookupUnknownSourceIdReturnsNil() async throws {
        let photo = FakeSource(id: "lib", photos: [snap("photo:1")])
        let composite = CompositeMediaSource(library: photo, others: [FakeSource(id: "s1", photos: [snap("folder:s1:x")])])
        let unknown = try await composite.lookup("folder:gone:z")
        XCTAssertNil(unknown, "装配里没有的 sourceId：路由不到，不误落 library")
    }

    // libraryIdentity / currentPosition 只取 PhotoKit；目录来源 nil 不触发重置。
    func testLibrarySemanticsComeFromPhotoKitOnly() async throws {
        let photo = FakeSource(id: "lib")
        let folder = FakeSource(id: "folder-s1")
        let composite = CompositeMediaSource(library: photo, others: [folder])
        let identity = try await composite.libraryIdentity()
        XCTAssertEqual(identity, "lib-1")
        let position = try await composite.currentPosition()
        XCTAssertEqual(String(decoding: position.raw, as: UTF8.self), "pos-lib")
    }

    // preciseDiscovery：全部来源精确才精确（目录来源显式 false → Composite false）。
    func testPreciseDiscoveryRequiresAllSources() {
        let photo = FakeSource(id: "lib")
        let folder = FakeSource(id: "folder-s1")
        folder.precise.set(false) // 真实 FolderMediaSource 恒 false；这里用 double 复现该语义
        let composite = CompositeMediaSource(library: photo, others: [folder])
        XCTAssertFalse(composite.preciseDiscovery)
        photo.precise.set(true)
        folder.precise.set(true)
        XCTAssertTrue(composite.preciseDiscovery)
    }

    // MARK: CompositeImporter

    // import 按前缀 + sourceId 分发：folder:<sourceId> → 对应目录导入器，photo: → PhotoKit 导入器。
    func testImportRoutesByPrefix() async throws {
        let photo = FakeImporter(folderSourceId: "lib-i")
        let folder = FakeImporter(folderSourceId: "s1")
        let composite = CompositeImporter(library: photo, others: [folder])
        let p = try await composite.importMedia(MediaDetails(snapshot: snap("photo:1"), fileName: "a", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)) { _ in }
        XCTAssertEqual(p, .imported(contentHash: "hash-photo:1", sizeBytes: 1))
        let f = try await composite.importMedia(MediaDetails(snapshot: snap("folder:s1:x"), fileName: "b", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)) { _ in }
        XCTAssertEqual(f, .imported(contentHash: "hash-folder:s1:x", sizeBytes: 1))
    }

    // 多目录来源：import 按 mediaId 里的 sourceId 精确分发到对应的目录导入器（不只 others.first）。
    // 反证：全部 folder id 都发给第一个导入器 → 预置在 s2 上的结果不会返回 → 红。
    func testImportRoutesToMatchingSourceImporter() async throws {
        let s1 = FakeImporter(folderSourceId: "s1")
        let s2 = FakeImporter(folderSourceId: "s2")
        s2.results.update { $0["folder:s2:y"] = .imported(contentHash: "from-s2", sizeBytes: 2) }
        let composite = CompositeImporter(library: FakeImporter(folderSourceId: "lib-i"), others: [s1, s2])
        let f = try await composite.importMedia(MediaDetails(snapshot: snap("folder:s2:y"), fileName: "b", mimeType: "image/jpeg", sizeBytes: 2, captureAtMs: 0)) { _ in }
        XCTAssertEqual(f, .imported(contentHash: "from-s2", sizeBytes: 2), "folder:s2 要路由到 s2 的导入器")
        let g = try await composite.importMedia(MediaDetails(snapshot: snap("folder:s1:x"), fileName: "a", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)) { _ in }
        XCTAssertEqual(g, .imported(contentHash: "hash-folder:s1:x", sizeBytes: 1), "folder:s1 要路由到 s1 的导入器")
    }

    // release 广播给全部子导入器（各自幂等清理）；不按 contentHash 推断来源。
    // 反证：只广播给「来源推断的那个」→ 另一个导入器的 released 为空 → 红。
    func testReleaseBroadcastsToAll() {
        let photo = FakeImporter(folderSourceId: "lib-i")
        let folder = FakeImporter(folderSourceId: "s1")
        let composite = CompositeImporter(library: photo, others: [folder])
        composite.release("some-hash")
        composite.release("some-hash")
        XCTAssertEqual(photo.released.get(), ["some-hash", "some-hash"], "广播且幂等：两次调用两次送达")
        XCTAssertEqual(folder.released.get(), ["some-hash", "some-hash"], "广播且幂等：两次调用两次送达")
    }

    // 装配里没有该 sourceId 的目录来源却收到 folder: 的 id → 直接暴露（装配错误）。
    func testFolderIdWithoutFolderSourceThrows() async throws {
        let composite = CompositeImporter(library: FakeImporter(folderSourceId: "lib-i"), others: [])
        do {
            _ = try await composite.importMedia(MediaDetails(snapshot: snap("folder:s1:x"), fileName: "b", mimeType: "image/jpeg", sizeBytes: 1, captureAtMs: 0)) { _ in }
            XCTFail("要抛 FolderMediaMissing")
        } catch is FolderMediaMissing {
            // 期望
        } catch {
            XCTFail("错误类型不对：\(type(of: error))")
        }
    }
}
