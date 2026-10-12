import XCTest
import Photos
@testable import PPassMedia

/// 可编排的原图来源：按块吐字节，可在第 k 块后抛错，或在某一块之后挂起等取消。
final class FakeOriginalSource: OriginalResourceSource, @unchecked Sendable {
    enum Step { case chunk(Data), fail(Error), hangUntilCancelled }

    var resolveResult: Result<OriginalResourceInfo, OriginalFetchFailure>
    var steps: [Step]
    private(set) var progressReported: [Double] = []

    init(filename: String = "IMG_0001.HEIC", steps: [Step]) {
        resolveResult = .success(OriginalResourceInfo(assetId: "asset-1", originalFilename: filename, uniformTypeIdentifier: "public.heic", resourceType: .photo))
        self.steps = steps
    }

    func resolveOriginal(assetId: String) throws -> OriginalResourceInfo { try resolveResult.get() }

    func streamData(of resource: OriginalResourceInfo, progress: @escaping @Sendable (Double) -> Void, chunk: @escaping (Data) throws -> Void) async throws {
        for (i, step) in steps.enumerated() {
            switch step {
            case .chunk(let data):
                try chunk(data)
                let p = Double(i + 1) / Double(steps.count)
                progressReported.append(p)
                progress(p)
            case .fail(let error):
                throw error
            case .hangUntilCancelled:
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                // 对齐 PhotoKit：被 cancelDataRequest 后完成回调带 3072。
                throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.userCancelled.rawValue)
            }
        }
    }
}

/// IOS-11（#337）：取原图的流式写入、清理、错误分类。
final class OriginalFetcherTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fetcher-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    func testChunksAreStreamedToTempFileWithOriginalExtensionAndDiscardCleansUp() async throws {
        let source = FakeOriginalSource(steps: [.chunk(Data("ab".utf8)), .chunk(Data("cd".utf8)), .chunk(Data("e".utf8))])
        let fetcher = OriginalFetcher(source: source, tempRoot: root)

        let fetched = try await fetcher.fetch(assetId: "asset-1")

        XCTAssertEqual(try Data(contentsOf: fetched.fileURL), Data("abcde".utf8))
        XCTAssertEqual(fetched.sizeBytes, 5)
        XCTAssertEqual(fetched.fileURL.pathExtension, "HEIC")
        XCTAssertEqual(fetched.info.mimeType, "image/heic")
        XCTAssertEqual(source.progressReported.count, 3)
        fetched.discard()
        fetched.discard()
        XCTAssertEqual(leftovers(), [], "discard 删掉这次的目录，重复调用无害")
    }

    func testReleasingWithoutDiscardStillCleansUp() async throws {
        let fetcher = OriginalFetcher(source: FakeOriginalSource(steps: [.chunk(Data([1, 2, 3]))]), tempRoot: root)
        var fetched: FetchedOriginal? = try await fetcher.fetch(assetId: "asset-1")
        XCTAssertEqual(leftovers().count, 1)
        fetched = nil
        XCTAssertNil(fetched)
        XCTAssertEqual(leftovers(), [], "调用方忘了 discard，对象释放时兜底删除")
    }

    func testHashIsComputedOverTheWholeFileAndHashFailureCleansUp() async throws {
        let fetcher = OriginalFetcher(source: FakeOriginalSource(steps: [.chunk(Data("he".utf8)), .chunk(Data("llo".utf8))]), tempRoot: root)

        let (fetched, hash) = try await fetcher.fetchAndHash(assetId: "asset-1") { url in
            "len=\(try Data(contentsOf: url).count)"
        }
        XCTAssertEqual(hash, "len=5", "哈希函数拿到的是完整文件")
        fetched.discard()

        struct HasherBroke: Error {}
        do {
            _ = try await fetcher.fetchAndHash(assetId: "asset-1") { _ in throw HasherBroke() }
            XCTFail("expected hasher error")
        } catch is HasherBroke {}
        XCTAssertEqual(leftovers(), [], "哈希失败也不留临时文件")
    }

    // MARK: D4 分类：网络 → 等待、不计次；不可得 → 计次；源已删；本地空间

    func testNetworkFailureMidDownloadIsWaitNotFailureAndLeavesNothing() async {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let source = FakeOriginalSource(steps: [.chunk(Data(repeating: 7, count: 1024)), .fail(offline)])
        let fetcher = OriginalFetcher(source: source, tempRoot: root)

        do {
            _ = try await fetcher.fetch(assetId: "asset-1")
            XCTFail("expected failure")
        } catch let failure as OriginalFetchFailure {
            guard case .network = failure else { return XCTFail("got \(failure)") }
            XCTAssertFalse(failure.countsAgainstFailureBudget, "网络原因不扣失败预算")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(leftovers(), [], "下到一半断网，半截文件已删")
    }

    func testUnavailableResourceCountsAgainstBudget() async {
        let missing = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.missingResource.rawValue)
        let fetcher = OriginalFetcher(source: FakeOriginalSource(steps: [.fail(missing)]), tempRoot: root)
        do {
            _ = try await fetcher.fetch(assetId: "asset-1")
            XCTFail("expected failure")
        } catch let failure as OriginalFetchFailure {
            guard case .unavailable = failure else { return XCTFail("got \(failure)") }
            XCTAssertTrue(failure.countsAgainstFailureBudget)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testSourceMissingAndNoOriginalResourcePassThroughUntouched() async {
        for expected in [OriginalFetchFailure.sourceMissing, .unavailable(reason: "no original resource")] {
            let source = FakeOriginalSource(steps: [])
            source.resolveResult = .failure(expected)
            do {
                _ = try await OriginalFetcher(source: source, tempRoot: root).fetch(assetId: "gone")
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? OriginalFetchFailure, expected)
            }
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testLocalWriteOutOfSpaceIsItsOwnCategory() async {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                           userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        let fetcher = OriginalFetcher(source: FakeOriginalSource(steps: [.fail(full)]), tempRoot: root)
        do {
            _ = try await fetcher.fetch(assetId: "asset-1")
            XCTFail("expected failure")
        } catch let failure as OriginalFetchFailure {
            guard case .localStorageFull = failure else { return XCTFail("got \(failure)") }
            XCTAssertFalse(failure.countsAgainstFailureBudget, "手机没空间不是这张照片的错")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCancellationStopsDownloadThrowsCancellationErrorAndCleansUp() async throws {
        let source = FakeOriginalSource(steps: [.chunk(Data(repeating: 1, count: 4096)), .hangUntilCancelled])
        let fetcher = OriginalFetcher(source: source, tempRoot: root)

        let task = Task { try await fetcher.fetch(assetId: "asset-1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(leftovers().count, 1, "下载进行中，临时目录存在")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(leftovers(), [], "取消后半截文件已删")
    }

    func testPurgeLeftoversClearsCrashRemnants() throws {
        let stale = root.appendingPathComponent("crashed-run")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([1]).write(to: stale.appendingPathComponent("original.jpg"))
        OriginalFetcher(source: FakeOriginalSource(steps: []), tempRoot: root).purgeLeftovers()
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: 分类表

    func testClassifierTable() {
        func c(_ domain: String, _ code: Int, underlying: NSError? = nil) -> OriginalFetchFailure {
            var info: [String: Any] = [:]
            if let underlying { info[NSUnderlyingErrorKey] = underlying }
            return OriginalFetchErrorClassifier.classify(NSError(domain: domain, code: code, userInfo: info))
        }
        func kind(_ f: OriginalFetchFailure) -> String {
            switch f {
            case .sourceMissing: return "missing"
            case .network: return "network"
            case .localStorageFull: return "space"
            case .unavailable: return "unavailable"
            }
        }
        XCTAssertEqual(kind(c(NSURLErrorDomain, NSURLErrorTimedOut)), "network")
        XCTAssertEqual(kind(c(NSURLErrorDomain, NSURLErrorNetworkConnectionLost)), "network")
        XCTAssertEqual(kind(c(PHPhotosErrorDomain, 3169)), "network", "PHPhotosErrorNetworkError")
        XCTAssertEqual(kind(c(NSPOSIXErrorDomain, Int(ENETUNREACH))), "network")
        XCTAssertEqual(kind(c("CloudPhotoLibraryErrorDomain", 1005, underlying: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))), "network",
                       "外层是 iCloud 的错误、里层是断网：按里层归为网络")
        XCTAssertEqual(kind(c("CloudPhotoLibraryErrorDomain", 1005)), "unavailable", "认不出原因的 iCloud 错误不许猜成网络")
        XCTAssertEqual(kind(c(NSURLErrorDomain, NSURLErrorCancelled)), "unavailable", "URL 层的取消不是网络问题")
        XCTAssertEqual(kind(c(PHPhotosErrorDomain, 3164)), "unavailable", "networkAccessRequired 只会在没开网络时出现，是编码错误，不等网络")
        XCTAssertEqual(kind(c(PHPhotosErrorDomain, 3303)), "unavailable", "missingResource")
        XCTAssertEqual(kind(c(PHPhotosErrorDomain, 3302)), "unavailable", "invalidResource")
        XCTAssertEqual(kind(c(PHPhotosErrorDomain, 3306)), "unavailable", "requestNotSupportedForAsset")
        XCTAssertEqual(kind(c(PHPhotosErrorDomain, 3305)), "space", "notEnoughSpace")
        XCTAssertEqual(kind(c(NSPOSIXErrorDomain, Int(ENOSPC))), "space")
        XCTAssertTrue(OriginalFetchErrorClassifier.isUserCancelled(NSError(domain: PHPhotosErrorDomain, code: 3072)))
    }

    // MARK: 资源选择

    func testOriginalResourceSelection() {
        XCTAssertEqual(selectOriginalResource(types: [.adjustmentData, .fullSizePhoto, .photo], mediaType: .image), 2, "编辑过的照片取未编辑的原图")
        XCTAssertEqual(selectOriginalResource(types: [.photo, .pairedVideo], mediaType: .image), 0, "实况只取静态图")
        XCTAssertEqual(selectOriginalResource(types: [.photo, .alternatePhoto], mediaType: .image), 0, "RAW+JPEG 取 .photo")
        XCTAssertEqual(selectOriginalResource(types: [.fullSizeVideo, .video], mediaType: .video), 1)
        XCTAssertNil(selectOriginalResource(types: [.fullSizePhoto], mediaType: .image), "只有渲染结果没有原图：不可得")
        XCTAssertNil(selectOriginalResource(types: [.audio], mediaType: .audio))
    }
}
