// 卡 #1944：iOS 备份范围页加载封面误拉 iCloud 且未取消请求，导致部分空白与退出重进卡死「正在读取相册…」。
//
// 验收场景（纯内存注入 E2 单测，带反证）：
// 1. O(1) 封面查询：调用 1 次 `albums()` + 并发调用 20 次 `cover(_:side:)`，底层 `collections()` 只被调用 1 次
//    （旧代码每张封面重扫全量相册，调用 21 次），且空相册（`coverAssetId == nil`）0 次图片请求直接返回 nil。
// 2. 禁止拉取 iCloud：选范围封面请求必须 `isNetworkAccessAllowed == false`、`deliveryMode == .fastFormat`、
//    `resizeMode == .fast`，直接读系统本地缓存缩略图，绝不触发 iCloud 下载。
// 3. 退出取消立即生效、重进不卡死：注入挂起不回调的图片请求器，并发启动 12 个 `cover(_:side:)` 后全部 `.cancel()`，
//    12 个任务在 < 0.2s 内全部返回 nil，`cancelImageRequest` 被调用 12 次，紧接着再次调用 `albums()` 在 < 0.2s 内正常返回。
import Foundation
import Photos
import PPassCore
import PPassMedia
import UIKit
import XCTest
@testable import PPass

final class LiveMediaScopeTests: XCTestCase {
    private struct StubAuth: PhotoAuthorizationProviding {
        let level: PhotoAccessLevel
        func currentLevel() -> PhotoAccessLevel { level }
        func requestFullAccess() async -> PhotoAccessLevel { level }
    }

    /// 记录 `collections()` 与 `summary(ofCollection:)` 调用次数的内存相册库。
    private final class CountingPhotoLibrary: PhotoLibraryReading, @unchecked Sendable {
        private let lock = NSLock()
        private let items: [(collection: LibraryCollection, summary: CollectionSummary)]
        private(set) var collectionsCalls = 0
        private(set) var summaryCalls = 0
        private(set) var collectionsCalledOnMainThread = false

        init(albumCount: Int, includeEmptyAlbum: Bool = true) {
            var built: [(LibraryCollection, CollectionSummary)] = []
            built.append((
                LibraryCollection(id: "recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary),
                CollectionSummary(imageCount: 100, videoCount: 5, newestAssetId: "asset-recents")
            ))
            let regularCount = includeEmptyAlbum ? max(albumCount - 2, 0) : max(albumCount - 1, 0)
            for i in 1...regularCount {
                built.append((
                    LibraryCollection(id: "album-\(i)", title: "Album \(i)", type: .album, subtype: .albumRegular),
                    CollectionSummary(imageCount: i, videoCount: 0, newestAssetId: "asset-\(i)")
                ))
            }
            if includeEmptyAlbum {
                built.append((
                    LibraryCollection(id: "album-empty", title: "Empty", type: .album, subtype: .albumRegular),
                    CollectionSummary(imageCount: 0, videoCount: 0, newestAssetId: nil)
                ))
            }
            self.items = built
        }

        func collections() -> [LibraryCollection] {
            let onMain = Thread.isMainThread
            return lock.withLock {
                collectionsCalls += 1
                if onMain { collectionsCalledOnMainThread = true }
                return items.map(\.collection)
            }
        }

        func summary(ofCollection id: String) -> CollectionSummary? {
            lock.withLock {
                summaryCalls += 1
                return items.first(where: { $0.collection.id == id })?.summary
            }
        }

        func assetIdentifiers(inCollection id: String) -> [String]? { [] }
        func assetIdentifiers(inCollection id: String, among assetIds: [String]) -> [String]? { [] }
        func userAlbumIdentifiers(containing assetIds: [String]) -> [String: [String]] { [:] }
    }

    private func makeDummyImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private final class CoverSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var nextReqId: PHImageRequestID = 100
        private var _requestedAssets: [String] = []
        private var _capturedOptions: [PHImageRequestOptions] = []
        private var _pendingCompletions: [LiveMediaLibrary.CoverImageCompletion] = []
        private var _cancelledIds: [PHImageRequestID] = []
        private var _timedOut = false

        var requestedAssets: [String] { lock.withLock { _requestedAssets } }
        var capturedOptions: [PHImageRequestOptions] { lock.withLock { _capturedOptions } }
        var cancelledIds: [PHImageRequestID] { lock.withLock { _cancelledIds } }
        var timedOut: Bool { lock.withLock { _timedOut } }

        func recordAsset(_ assetId: String) {
            lock.withLock { _requestedAssets.append(assetId) }
        }

        func recordOptions(_ options: PHImageRequestOptions) {
            lock.withLock { _capturedOptions.append(options) }
        }

        func enqueuePending(_ completion: @escaping LiveMediaLibrary.CoverImageCompletion) -> PHImageRequestID {
            lock.withLock {
                defer { nextReqId += 1 }
                _pendingCompletions.append(completion)
                return nextReqId
            }
        }

        func recordCancel(_ id: PHImageRequestID) {
            lock.withLock { _cancelledIds.append(id) }
        }

        func drainPending(markTimedOut: Bool) -> [LiveMediaLibrary.CoverImageCompletion] {
            lock.withLock {
                if markTimedOut { _timedOut = true }
                let copy = _pendingCompletions
                _pendingCompletions.removeAll()
                return copy
            }
        }
    }

    // MARK: - 1. O(1) 封面查询：albums() + 20 张封面只扫 1 次相册目录，空相册不发图片请求

    func test_albums_and_20_covers_query_catalog_only_once_and_skip_empty_album_cover() async throws {
        let library = CountingPhotoLibrary(albumCount: 20, includeEmptyAlbum: true)
        let dummy = makeDummyImage()
        let spy = CoverSpy()

        let media = LiveMediaLibrary(
            scopeStore: { fatalError("本用例不读持久范围") },
            auth: StubAuth(level: .full),
            library: library,
            requestCoverImage: { assetId, _, _, _, resultHandler in
                spy.recordAsset(assetId)
                resultHandler(dummy, nil)
                return 1
            }
        )

        let albums = try await media.albums()
        XCTAssertEqual(albums.count, 20)
        XCTAssertEqual(library.collectionsCalls, 1, "albums() 枚举 1 次相册目录")
        XCTAssertNil(albums.first(where: { $0.id == "album-empty" })?.coverAssetId, "空相册 coverAssetId 应为 nil")
        XCTAssertEqual(albums.first(where: { $0.id == "recents" })?.coverAssetId, "asset-recents")

        await withTaskGroup(of: (String, UIImage?).self) { group in
            for album in albums {
                group.addTask {
                    let img = await media.cover(album, side: 120)
                    return (album.id, img)
                }
            }
            var nonNilCount = 0
            for await (albumId, img) in group {
                if albumId == "album-empty" {
                    XCTAssertNil(img, "空相册应直接返回 nil")
                } else {
                    XCTAssertNotNil(img, "非空相册 \(albumId) 应返回本地缩略图")
                    nonNilCount += 1
                }
            }
            XCTAssertEqual(nonNilCount, 19)
        }

        XCTAssertEqual(library.collectionsCalls, 1, "加载 20 张封面不得再次调用 catalog.listAlbums()（旧代码会调 21 次）")
        XCTAssertEqual(library.summaryCalls, 20, "每个相册的 summary 只在 albums() 期间查 1 次")
        XCTAssertEqual(spy.requestedAssets.count, 19, "空相册不触发 PHImageManager 请求")
    }

    // MARK: - 2. 禁止拉取 iCloud：强制 isNetworkAccessAllowed == false + .fastFormat + .fast

    func test_cover_request_disables_icloud_network_and_uses_fast_local_thumbnail() async throws {
        let defaults = LiveMediaLibrary.coverRequestOptions()
        XCTAssertFalse(defaults.isNetworkAccessAllowed, "选备份范围封面绝不能联网拉取 iCloud")
        XCTAssertEqual(defaults.deliveryMode, .fastFormat, "选备份范围封面应直接读系统本地缓存缩略图")
        XCTAssertEqual(defaults.resizeMode, .fast)

        let library = CountingPhotoLibrary(albumCount: 2, includeEmptyAlbum: false)
        let dummy = makeDummyImage()
        let spy = CoverSpy()

        let media = LiveMediaLibrary(
            scopeStore: { fatalError("本用例不读持久范围") },
            auth: StubAuth(level: .full),
            library: library,
            requestCoverImage: { _, _, _, options, resultHandler in
                spy.recordOptions(options)
                resultHandler(dummy, nil)
                return 7
            }
        )

        let albums = try await media.albums()
        let first = try XCTUnwrap(albums.first)
        let image = await media.cover(first, side: 120)
        XCTAssertNotNil(image)

        let passed = try XCTUnwrap(spy.capturedOptions.first)
        XCTAssertFalse(passed.isNetworkAccessAllowed, "传入请求器的 PHImageRequestOptions 必须禁止网络访问")
        XCTAssertEqual(passed.deliveryMode, .fastFormat)
        XCTAssertEqual(passed.resizeMode, .fast)
    }

    // MARK: - 3. 退出取消立即生效、重进不卡死

    func test_cancelling_inflight_covers_cancels_phimage_requests_immediately_and_reentry_albums_does_not_block() async throws {
        let library = CountingPhotoLibrary(albumCount: 12, includeEmptyAlbum: false)
        let spy = CoverSpy()
        let allStarted = expectation(description: "12 个封面请求全部发起")
        allStarted.expectedFulfillmentCount = 12

        // 即使旧代码未在 onCancel 里唤醒 continuation，测试结束时也兜底唤醒，避免测试进程死锁。
        defer {
            for c in spy.drainPending(markTimedOut: false) { c(nil, [PHImageCancelledKey: true]) }
        }

        let media = LiveMediaLibrary(
            scopeStore: { fatalError("本用例不读持久范围") },
            auth: StubAuth(level: .full),
            library: library,
            requestCoverImage: { _, _, _, _, resultHandler in
                let id = spy.enqueuePending(resultHandler)
                allStarted.fulfill()
                return id
            },
            cancelCoverImage: { reqId in
                spy.recordCancel(reqId)
            }
        )

        let albums = try await media.albums()
        XCTAssertEqual(albums.count, 12)

        let tasks = albums.map { album in
            Task { () -> UIImage? in
                await media.cover(album, side: 120)
            }
        }

        await fulfillment(of: [allStarted], timeout: 1.0)

        let cancelStart = ContinuousClock.now
        for task in tasks { task.cancel() }

        // 用 0.25s 超时竞速：修复后应在几毫秒内全部返回 nil；未修复时 continuation 永不唤醒，0.25s 超时分支兜底解锁并判红。
        let completedInTime: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for task in tasks {
                    let img = await task.value
                    if img != nil { return false }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return true }
                for c in spy.drainPending(markTimedOut: true) { c(nil, [PHImageCancelledKey: true]) }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first && !spy.timedOut
        }
        let cancelElapsed = ContinuousClock.now - cancelStart

        XCTAssertEqual(spy.cancelledIds.count, 12, "取消 12 个封面 Task 必须立即调用 12 次 cancelImageRequest")
        XCTAssertTrue(completedInTime, "取消后所有 cover(_:side:) 必须在 0.2s 内立即返回 nil，不能等待挂起的图片回调（耗时 \(cancelElapsed)）")
        XCTAssertLessThan(cancelElapsed, .milliseconds(200))

        // 模拟退出后再次进入「备份范围」页：albums() 必须在 < 0.2s 内正常返回全部相册。
        let reentryStart = ContinuousClock.now
        let reloaded = try await media.albums()
        let reentryElapsed = ContinuousClock.now - reentryStart
        XCTAssertEqual(reloaded.count, 12)
        XCTAssertLessThan(reentryElapsed, .milliseconds(200), "重进页面读取相册不得被上一轮残留在途请求阻塞")
    }

    private final class BlockingPhotoLibrary: PhotoLibraryReading, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private(set) var calledOnMainThread = false

        func collections() -> [LibraryCollection] {
            calledOnMainThread = Thread.isMainThread
            entered.signal()
            _ = release.wait(timeout: .now() + 2.0)
            return [LibraryCollection(id: "recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary)]
        }

        func summary(ofCollection id: String) -> CollectionSummary? {
            CollectionSummary(imageCount: 1, videoCount: 0, newestAssetId: "a1")
        }

        func assetIdentifiers(inCollection id: String) -> [String]? { [] }
        func assetIdentifiers(inCollection id: String, among assetIds: [String]) -> [String]? { [] }
        func userAlbumIdentifiers(containing assetIds: [String]) -> [String: [String]] { [:] }
    }

    @MainActor
    func test_existingAlbumIds_runs_on_catalog_queue_and_returns_immediately_on_cancel() async {
        let normalLib = CountingPhotoLibrary(albumCount: 4, includeEmptyAlbum: true)
        let normalMedia = LiveMediaLibrary(
            scopeStore: { fatalError("本用例不读持久范围") },
            auth: StubAuth(level: .full),
            library: normalLib
        )
        let ids = await normalMedia.existingAlbumIds()
        XCTAssertEqual(ids, ["recents", "album-1", "album-2", "album-empty"])
        XCTAssertFalse(normalLib.collectionsCalledOnMainThread)

        let blockingLib = BlockingPhotoLibrary()
        defer { blockingLib.release.signal() }
        let blockingMedia = LiveMediaLibrary(
            scopeStore: { fatalError("本用例不读持久范围") },
            auth: StubAuth(level: .full),
            library: blockingLib
        )
        let task = Task { await blockingMedia.existingAlbumIds() }
        // 在后台线程等 collections() 真正进入慢查询，不阻塞当前主线程
        await Task.detached { _ = blockingLib.entered.wait(timeout: .now() + 1.0) }.value

        let cancelStart = ContinuousClock.now
        task.cancel()
        let completedFast: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let res = await task.value
                return res == nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return true }
                blockingLib.release.signal()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let elapsed = ContinuousClock.now - cancelStart
        XCTAssertFalse(blockingLib.calledOnMainThread)
        XCTAssertTrue(completedFast, "取消 existingAlbumIds() 必须立即释放等待并返回 nil，不得占住调用方等待慢速全量扫描（耗时 \(elapsed)）")
    }
}
