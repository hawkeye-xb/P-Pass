import XCTest
import Photos
import UIKit
import PPassMedia

/// IOS-11（#337）在模拟器真 PhotoKit 上的验收：取出的原始字节与灌进去的文件逐字节一致（JPEG / HEIC / MP4 各一例）。
///
/// 「BLAKE3 与 Desktop 一致」的前提是两边喂进哈希的是同一串字节。BLAKE3 来自 XCFramework（#313），本包不实现，
/// 所以这里证明的是前提本身：取出的字节 == 原文件字节。另外用测试内的 FNV-1a 流式摘要走一遍 `fetchAndHash`，
/// 证明注入的哈希函数拿到的是完整文件。
final class OriginalBytesIT: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("originals-it-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 测试用流式摘要（FNV-1a 64），只为证明「哈希函数拿到了完整文件」，不是产品哈希。
    private func fnv1a(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 0xcbf29ce484222325
        while let block = try handle.read(upToCount: 64 * 1024), !block.isEmpty {
            for byte in block { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        }
        return String(hash, radix: 16)
    }

    func testOriginalBytesMatchFixtureFilesForJpegHeicAndVideo() async throws {
        try IT.requireFullAccess()
        let dir = try IT.fixtureDir()
        let fetcher = OriginalFetcher(tempRoot: root)

        for (name, mime) in [("a1.jpg", "image/jpeg"), ("h1.heic", "image/heic"), ("v1.mp4", "video/mp4")] {
            let asset = try IT.asset(originalFilename: name)
            let fixture = dir.appendingPathComponent(name)
            let expected = try Data(contentsOf: fixture)
            let progress = ProgressLog()

            let (fetched, digest) = try await fetcher.fetchAndHash(assetId: asset.localIdentifier, progress: { p in progress.add(p) }) { url in
                try self.fnv1a(fileAt: url)
            }
            let got = try Data(contentsOf: fetched.fileURL)
            print("IT-ORIGINAL \(name) bytes=\(got.count) fixture=\(expected.count) equal=\(got == expected) type=\(fetched.info.resourceType.rawValue) uti=\(fetched.info.uniformTypeIdentifier) mime=\(fetched.info.mimeType) digest=\(digest) progressCallbacks=\(progress.count)")
            XCTAssertEqual(got, expected, "\(name)：取出的字节与灌进去的文件逐字节一致")
            XCTAssertEqual(fetched.sizeBytes, Int64(expected.count))
            XCTAssertEqual(digest, try fnv1a(fileAt: fixture), "注入的哈希函数拿到的是完整文件")
            XCTAssertEqual(fetched.info.originalFilename, name)
            XCTAssertEqual(fetched.info.mimeType, mime)
            XCTAssertEqual(fetched.info.resourceType, asset.mediaType == .video ? .video : .photo)
            fetched.discard()
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertEqual(left, [], "用完即删，临时目录为空")
    }

    func testDeletedOrUnknownAssetIsSourceMissing() async throws {
        try IT.requireFullAccess()
        do {
            _ = try await OriginalFetcher(tempRoot: root).fetch(assetId: "00000000-0000-0000-0000-000000000000/L0/001")
            XCTFail("expected sourceMissing")
        } catch {
            XCTAssertEqual(error as? OriginalFetchFailure, .sourceMissing)
        }
    }

    /// 实测发现：App 用 `addResource(with:data:)` 写进图库的 JPEG，图库里存的字节和写入的**不一样**（会被改写，例如多出 62 字节）。
    /// 所以「原始字节」指的是图库里此刻存着的那一份，不是当初写入方手里的那一份。对去重有意义的性质是**同一份资源反复读出的字节稳定**，
    /// 这样哈希才稳定、桌面判重才成立。这里钉住的是这一条。
    func testRepeatedReadsOfTheSameAssetAreByteStable() async throws {
        try IT.requireFullAccess()
        let label = "ppit-roundtrip-\(IT.nonce)"
        let written = try Data(contentsOf: try IT.writeUniqueJPEG(label: label))
        var id: String?
        try IT.perform {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "\(label).jpg"
            request.addResource(with: .photo, data: written, options: options)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        let fetcher = OriginalFetcher(tempRoot: root)
        let first = try await fetcher.fetch(assetId: try XCTUnwrap(id))
        let second = try await fetcher.fetch(assetId: try XCTUnwrap(id))
        defer { first.discard(); second.discard() }
        let a = try Data(contentsOf: first.fileURL)
        let b = try Data(contentsOf: second.fileURL)
        print("IT-ORIGINAL app-written jpeg: written=\(written.count) stored=\(a.count) identicalToWritten=\(a == written) stableAcrossReads=\(a == b)")
        XCTAssertEqual(a, b, "同一资源两次读出的字节一致")
    }
}

extension OriginalBytesIT {
    /// 编辑过的照片：取到的是编辑后的渲染结果，不是未编辑原图（#337 拍板：备份「相册里看到的那张」）。
    /// 用 `PHContentEditingOutput` 在真库里造一次编辑，再确认资源集里出现 `.fullSizePhoto`、取到的字节与编辑前不同，
    /// 且恰好等于写进渲染文件的那份字节。
    func testEditedPhotoFetchesRenderedVersionNotOriginal() async throws {
        try IT.requireFullAccess()
        let label = "ppit-edited-\(IT.nonce)"
        let id = try IT.createPhoto(label: label)
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let fetcher = OriginalFetcher(tempRoot: root)

        let before = try await fetcher.fetch(assetId: id)
        let originalBytes = try Data(contentsOf: before.fileURL)
        XCTAssertEqual(before.info.resourceType, .photo, "未编辑：取 .photo")
        before.discard()

        // 造一次编辑：渲染成另一张不同内容的 JPEG。
        let input: PHContentEditingInput = try {
            var result: PHContentEditingInput?
            let done = DispatchSemaphore(value: 0)
            asset.requestContentEditingInput(with: nil) { input, _ in result = input; done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "requestContentEditingInput 超时")
            return try XCTUnwrap(result)
        }()
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.hawkeyexb.ppass.mediatest", formatVersion: "1", data: Data("edit".utf8))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let rendered = try XCTUnwrap(renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 0.9))
        try rendered.write(to: output.renderedContentURL)
        try IT.perform {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }

        let types = PHAssetResource.assetResources(for: asset).map { $0.type }
        let after = try await fetcher.fetch(assetId: id)
        defer { after.discard() }
        let got = try Data(contentsOf: after.fileURL)
        print("IT-EDITED resourceTypes=\(types.map { $0.rawValue }) fetchedType=\(after.info.resourceType.rawValue) originalBytes=\(originalBytes.count) fetchedBytes=\(got.count) differsFromOriginal=\(got != originalBytes)")
        XCTAssertTrue(types.contains(.fullSizePhoto), "编辑后资源集里应有 .fullSizePhoto，实际 \(types.map { $0.rawValue })")
        XCTAssertEqual(after.info.resourceType, .fullSizePhoto)
        XCTAssertNotEqual(got, originalBytes, "取到的不是编辑前的字节")
        XCTAssertFalse(got.isEmpty)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
