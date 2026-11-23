// 卡 #1935：对齐 Android #124（MOB-73），查看本机已备份照片/视频时优先读本机相册与文件夹原图。
//
// 验收场景（卡上原文）：
// 1. 【E2 单测 + 反证】给定 `isMine == true` + 账本 CONFIRMED 命中 + 本地可读且 `sourceVersion` 一致，
//    缩略图（256/1024）与原图（保存/分享/视频播放）均直接读本机，远端 ProtoClient / fetchBlob 调用次数为 0；
//    把本机优先分支旁路后测试变红。
// 2. 【E2 回退与防串图】非本机来源（`isMine != true`）/ 账本未命中 / `sourceMissing == true` /
//    本地读不到 / `sourceVersion` 不一致：全部静默回退远端，不报错且绝不显示错的照片。
// 3. 【E2 安全边界】证明新增路径未把 `mediaId` / `localIdentifier` / 本地路径传给任何上行 `ProtoClient` 接口，也不进日志。
import AVFoundation
import Foundation
import ImageIO
import Photos
import PPassCore
import PPassMedia
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PPass

final class LocalSourceFirstTests: XCTestCase {
    private var tempDir: URL!
    private let photoHash = String(repeating: "ab", count: 32)
    private let videoHash = String(repeating: "cd", count: 32)
    private let photoMediaId = "B2805351-9CD1-55C7-81B0-DBEAD9E86BD3/L0/001"
    private let photoVersion = "1:original"
    private let videoVersion = "2:original"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("local-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        LiveTimeline.clearShareDir()
        try? FileManager.default.removeItem(at: LiveTimeline.videoCacheDir)
    }

    override func tearDownWithError() throws {
        LiveTimeline.clearShareDir()
        try? FileManager.default.removeItem(at: LiveTimeline.videoCacheDir)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - 测试夹具

    private func makeJpeg(width: Int = 64, height: Int = 48, color: UIColor = .systemTeal) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return try XCTUnwrap(renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        })
    }

    private func makeTinyMovHeader(extraBytes: Int = 32) -> Data {
        // ftypqt  （12 字节）+ 填充字节，让 LiveTimeline.fileExtension 识别为 .mov
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x14] + Array("ftypqt  ".utf8) + [0x00, 0x00, 0x02, 0x00] + Array("qt  ".utf8)
        bytes += Array(repeating: 0x42, count: extraBytes)
        return Data(bytes)
    }

    /// 写一段真实可解码的 0.1s 64×48 .mov 视频文件，供目录源 AVAssetImageGenerator 首帧缩略图与原片复制测试。
    private func writeRealTinyMov(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 48,
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x99, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: 1, timescale: 10)))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func seedOrders(_ specs: [(mediaId: String, hash: String?, state: OrderState, sourceMissing: Bool, sourceVersion: String)]) throws -> [Order] {
        let dir = tempDir.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        let store = try SQLiteOrderStore(directory: dir, logger: LogCapture())
        defer { store.close() }
        for s in specs {
            let initial: OrderState = (s.state == .confirmed) ? .transferring : s.state
            let row = try store.insert(NewOrder(mediaId: s.mediaId, sourceVersion: s.sourceVersion, bucketId: "camera",
                                                contentHash: s.hash, state: initial, pairingId: "pair-1"))
            if s.state == .confirmed {
                _ = try store.transition(row.id, expected: [.transferring], to: .confirmed)
            }
            if s.sourceMissing {
                _ = try store.setSourceMissing(row.id, missing: true, audit: nil)
            }
        }
        return try store.currentOrders().collect()
    }

    private func item(hash: String, isVideo: Bool = false, bytes: Int64? = nil, isMine: Bool? = true) -> TimelineItem {
        TimelineItem(id: hash, takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                     isVideo: isVideo, width: 64, height: 48, bytes: bytes, isMine: isMine)
    }

    /// 假本机读取器：记录拿到的 mediaId / sourceVersion / maxPx，可模拟「版本不符 / 权限没了 / iCloud 未下载」。
    private final class FakeLocalReader: LocalOriginalReading, @unchecked Sendable {
        struct Call: Equatable {
            let mediaId: String
            let sourceVersion: String
            let isVideo: Bool
            let maxPx: Int
        }

        private let lock = NSLock()
        private(set) var thumbCalls: [Call] = []
        private(set) var copyCalls: [Call] = []
        var expectedVersion: String?
        var thumbImage: UIImage?
        var copyBytes: Data?

        init(expectedVersion: String? = nil, thumbImage: UIImage? = UIImage(systemName: "checkmark"), copyBytes: Data? = nil) {
            self.expectedVersion = expectedVersion
            self.thumbImage = thumbImage
            self.copyBytes = copyBytes
        }

        func thumb(mediaId: String, sourceVersion: String, isVideo: Bool, maxPx: Int) async -> UIImage? {
            lock.lock()
            thumbCalls.append(Call(mediaId: mediaId, sourceVersion: sourceVersion, isVideo: isVideo, maxPx: maxPx))
            let expected = expectedVersion
            let img = thumbImage
            lock.unlock()
            if let expected, expected != sourceVersion { return nil }
            return img
        }

        func copy(mediaId: String, sourceVersion: String, isVideo: Bool, dest: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
            lock.lock()
            copyCalls.append(Call(mediaId: mediaId, sourceVersion: sourceVersion, isVideo: isVideo, maxPx: 0))
            let expected = expectedVersion
            let payload = copyBytes
            lock.unlock()
            if let expected, expected != sourceVersion { return false }
            guard let payload else { return false }
            do {
                try payload.write(to: dest, options: .atomic)
                progress(1.0)
                return true
            } catch {
                try? FileManager.default.removeItem(at: dest)
                return false
            }
        }
    }

    /// 远端控制面 + blob 拉取计数与参数拦截桩。
    private final class RemoteSpy: CtrlTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var thumbCalls = 0
        private(set) var ticketCalls = 0
        private(set) var fetchBlobCalls = 0
        private(set) var wirePayloads: [String] = []
        let remoteJpeg: Data
        let remoteBlob: Data

        init(remoteJpeg: Data, remoteBlob: Data) {
            self.remoteJpeg = remoteJpeg
            self.remoteBlob = remoteBlob
        }

        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            let raw = String(decoding: paramsJSON, as: UTF8.self)
            lock.lock()
            wirePayloads.append("\(method):\(raw)")
            switch method {
            case Methods.thumbGet: thumbCalls += 1
            case Methods.assetBlobTicket: ticketCalls += 1
            default: break
            }
            lock.unlock()

            switch method {
            case Methods.thumbGet:
                let body = #"{"jpeg_base64":"\#(remoteJpeg.base64EncodedString())","placeholder":false}"#
                return try ProtoJSON.encode(Resp(id: "1", ok: true, result: try JSONValue.parse(Data(body.utf8))))
            case Methods.assetBlobTicket:
                // #1940：票据回带请求里的内容哈希，让 fetchBlob 桩能返回与任意条目匹配的哈希（照片/视频通用）。
                let object = (try? JSONSerialization.jsonObject(with: paramsJSON)) as? [String: Any]
                let requestedHash = (object?["hash"] as? String) ?? ""
                let body = #"{"ticket":"\#(requestedHash)"}"#
                return try ProtoJSON.encode(Resp(id: "1", ok: true, result: try JSONValue.parse(Data(body.utf8))))
            default:
                throw LiveTimeline.Failure.notPaired
            }
        }

        func fetchBlob(hash: String, ticket: String, dest: URL, progress: @escaping @Sendable (UInt64) -> Void) async throws -> String {
            lock.lock()
            fetchBlobCalls += 1
            wirePayloads.append("fetchBlob:\(ticket)")
            lock.unlock()
            try remoteBlob.write(to: dest)
            progress(UInt64(remoteBlob.count))
            return hash
        }
    }

    private final class LogCapture: CoreLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func log(_ message: String) { lock.lock(); entries.append(message); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    // MARK: - ① 本机命中：缩略图（256/1024）与原图（保存/分享/视频播放）全走本机，远端调用为 0

    func test_local_hit_serves_thumbnails_photo_and_video_originals_with_zero_remote_calls() async throws {
        let localPhotoBytes = try makeJpeg(width: 40, height: 30, color: .systemGreen)
        let localVideoBytes = makeTinyMovHeader(extraBytes: 64)
        let remoteJpeg = try makeJpeg(width: 16, height: 16, color: .systemRed)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: Data("remote-original".utf8))
        let logs = LogCapture()

        // 用真实 SQLiteOrderStore 写入 CONFIRMED 行，经 OrderStore.currentOrders() 构建索引（丙案全链路）。
        let store = try SQLiteOrderStore(directory: tempDir.appendingPathComponent("ledger", isDirectory: true), logger: logs)
        defer { store.close() }
        let pRow = try store.insert(NewOrder(mediaId: photoMediaId, sourceVersion: photoVersion, bucketId: "camera",
                                             contentHash: photoHash, state: .transferring, pairingId: "p1"))
        XCTAssertTrue(try store.transition(pRow.id, expected: [.transferring], to: .confirmed))
        let vRow = try store.insert(NewOrder(mediaId: "VIDEO-LOCAL-ID/L0/002", sourceVersion: videoVersion, bucketId: "camera",
                                             contentHash: videoHash, state: .transferring, pairingId: "p1"))
        XCTAssertTrue(try store.transition(vRow.id, expected: [.transferring], to: .confirmed))

        let localThumb = try XCTUnwrap(UIImage(data: localPhotoBytes))
        let reader = FakeLocalReader(thumbImage: localThumb, copyBytes: localPhotoBytes)
        let originals = LocalFirstOriginals(reader: reader, loadIndex: { LocalSourceIndex.read(from: store) })
        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { [photoHash] ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: photoHash, ticket: ticket, dest: dest, progress: progress)
            },
            logger: logs,
            freeBytes: { 0 }, // 即使剩余空间不足以下载远端视频，本机命中也不走远端下载预检（或仅拷一份）
            localOriginals: originals
        )

        let pItem = item(hash: photoHash, isVideo: false, bytes: Int64(localPhotoBytes.count), isMine: true)
        // 1) 256 网格缩略图 + 1024 查看器大图
        let t256 = try await timeline.thumbnail(pItem, large: false)
        let t1024 = try await timeline.thumbnail(pItem, large: true)
        XCTAssertEqual(t256.size, localThumb.size)
        XCTAssertEqual(t1024.size, localThumb.size)

        // 2) 保存 / 分享照片原图（RET-01：落在 tmp/ppass-share，discardShared 即清）
        let savedURL = try await timeline.original(pItem, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: savedURL), localPhotoBytes)
        XCTAssertEqual(savedURL.pathExtension, "jpg")
        LiveTimeline.discardShared(savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path), "RET-01：用完即删")

        let sharedURL = try await timeline.original(pItem, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: sharedURL), localPhotoBytes)
        LiveTimeline.discardShared(sharedURL)

        // 3) 视频原图播放/分享
        reader.copyBytes = localVideoBytes
        let vItem = item(hash: videoHash, isVideo: true, bytes: Int64(localVideoBytes.count), isMine: true)
        let videoURL = try await timeline.original(vItem, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: videoURL), localVideoBytes)
        XCTAssertEqual(videoURL.pathExtension, "mov")

        // 断言远端调用全部为 0
        XCTAssertEqual(remoteSpy.thumbCalls, 0, "本机命中时 thumb.get 调用次数必须为 0")
        XCTAssertEqual(remoteSpy.ticketCalls, 0, "本机命中时 asset.blob_ticket 调用次数必须为 0")
        XCTAssertEqual(remoteSpy.fetchBlobCalls, 0, "本机命中时 fetchBlob 调用次数必须为 0")
        XCTAssertEqual(reader.thumbCalls.map(\.maxPx), [256, 1024])
        XCTAssertEqual(reader.thumbCalls.map(\.sourceVersion), [photoVersion, photoVersion])
    }

    // MARK: - ② 回退与防串图：不满足条件时一律静默回退远端，绝不给错图

    func test_non_mine_items_skip_local_reader_and_fallback_to_remote() async throws {
        let remoteJpeg = try makeJpeg(width: 20, height: 20, color: .systemBlue)
        let remoteBlob = try makeJpeg(width: 32, height: 32, color: .systemOrange)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: remoteBlob)
        let reader = FakeLocalReader(copyBytes: Data("wrong-local".utf8))
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: photoMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion),
        ]))
        let originals = LocalFirstOriginals(reader: reader, loadIndex: { index })

        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { [photoHash] ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: photoHash, ticket: ticket, dest: dest, progress: progress)
            },
            logger: LogCapture(),
            localOriginals: originals
        )

        // isMine == false（家人的照片）与 isMine == nil（未知归属）都不读本机
        for mine in [false as Bool?, nil as Bool?] {
            timeline.clearMemoryCache()
            let target = item(hash: photoHash, isVideo: false, bytes: Int64(remoteBlob.count), isMine: mine)
            _ = try await timeline.thumbnail(target, large: false)
            let url = try await timeline.original(target, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: url), remoteBlob)
            LiveTimeline.discardShared(url)
        }

        XCTAssertTrue(reader.thumbCalls.isEmpty && reader.copyCalls.isEmpty, "非本机来源连本机读取器都不应触碰")
        XCTAssertEqual(remoteSpy.thumbCalls, 2)
        XCTAssertEqual(remoteSpy.ticketCalls, 2)
        XCTAssertEqual(remoteSpy.fetchBlobCalls, 2)
    }

    func test_unmatched_or_source_missing_or_unconfirmed_rows_fallback_to_remote() async throws {
        let remoteJpeg = try makeJpeg(width: 24, height: 24)
        let remoteBlob = try makeJpeg(width: 24, height: 24)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: remoteBlob)
        let reader = FakeLocalReader(copyBytes: Data("local".utf8))
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: "m1", hash: String(repeating: "11", count: 32), state: .confirmed, sourceMissing: true, sourceVersion: "1:original"),
            (mediaId: "m2", hash: String(repeating: "22", count: 32), state: .transferring, sourceMissing: false, sourceVersion: "1:original"),
            (mediaId: "m3", hash: String(repeating: "33", count: 32), state: .failed, sourceMissing: false, sourceVersion: "1:original"),
            (mediaId: "m4", hash: String(repeating: "44", count: 32), state: .pending, sourceMissing: false, sourceVersion: "1:original"),
            (mediaId: "m5", hash: nil, state: .confirmed, sourceMissing: false, sourceVersion: "1:original"),
        ]))
        XCTAssertFalse(index.hasEntries, "不可用的行一律不进索引")

        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: String(repeating: "11", count: 32), ticket: ticket, dest: dest, progress: progress)
            },
            logger: LogCapture(),
            localOriginals: LocalFirstOriginals(reader: reader, loadIndex: { index })
        )

        let target = item(hash: String(repeating: "11", count: 32), isMine: true)
        _ = try await timeline.thumbnail(target, large: true)
        let url = try await timeline.original(target, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: url), remoteBlob)
        LiveTimeline.discardShared(url)

        XCTAssertTrue(reader.thumbCalls.isEmpty && reader.copyCalls.isEmpty)
        XCTAssertEqual(remoteSpy.thumbCalls, 1)
        XCTAssertEqual(remoteSpy.fetchBlobCalls, 1)
    }

    func test_version_mismatch_or_unreadable_local_asset_falls_back_to_remote_without_wrong_image() async throws {
        let remoteJpeg = try makeJpeg(width: 28, height: 28, color: .purple)
        let remoteBlob = try makeJpeg(width: 28, height: 28, color: .purple)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: remoteBlob)
        // 账本记的是 1:original，但本机资源已变成 5:adj:deadbeef01234567 → 核对不一致返回 nil/false
        let reader = FakeLocalReader(expectedVersion: "5:adj:deadbeef01234567", copyBytes: Data("edited-other-image".utf8))
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: photoMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion),
        ]))

        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { [photoHash] ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: photoHash, ticket: ticket, dest: dest, progress: progress)
            },
            logger: LogCapture(),
            localOriginals: LocalFirstOriginals(reader: reader, loadIndex: { index })
        )

        let target = item(hash: photoHash, isMine: true)
        let thumb = try await timeline.thumbnail(target, large: true)
        XCTAssertEqual(Int(thumb.size.width), 28, "回退远端拿到远端缩略图，不展示错图")
        let url = try await timeline.original(target, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: url), remoteBlob, "回退远端拿到远端原图")
        LiveTimeline.discardShared(url)

        XCTAssertEqual(reader.thumbCalls.count, 1)
        XCTAssertEqual(reader.copyCalls.count, 1)
        XCTAssertEqual(remoteSpy.thumbCalls, 1)
        XCTAssertEqual(remoteSpy.fetchBlobCalls, 1)
    }

    // MARK: - 目录源（`folder:<sourceId>:<opaque>`）真文件端到端核对与读取

    func test_folder_source_reads_real_local_file_when_version_matches_and_rejects_modified_file() async throws {
        let logger = LogCapture()
        let registryDir = tempDir.appendingPathComponent("reg", isDirectory: true)
        let folderRoot = tempDir.appendingPathComponent("user-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)

        let registry = FolderRegistry(directory: registryDir, logger: logger)
        let sourceId = try registry.addFolder(at: folderRoot, displayName: "CameraCard")
        let fileURL = folderRoot.appendingPathComponent("sub/IMG_0001.jpg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let jpegBytes = try makeJpeg(width: 120, height: 80, color: .cyan)
        try jpegBytes.write(to: fileURL)

        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: "sub/IMG_0001.jpg")
        let folderMediaId = "folder:\(sourceId):\(opaque)"
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedMs = try XCTUnwrap(values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) })
        let recordedVersion = FolderMediaSource.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: Int64(jpegBytes.count))

        let iosReader = IOSOriginalReader(folders: registry, logger: logger)
        // 1) 版本一致：缩略图与原图复制成功
        let rawThumb = await iosReader.thumb(mediaId: folderMediaId, sourceVersion: recordedVersion, isVideo: false, maxPx: 64)
        let thumb = try XCTUnwrap(rawThumb)
        XCTAssertLessThanOrEqual(max(thumb.size.width * thumb.scale, thumb.size.height * thumb.scale), 64.5)

        let copied = tempDir.appendingPathComponent("copied.jpg")
        let ok = await iosReader.copy(mediaId: folderMediaId, sourceVersion: recordedVersion, isVideo: false, dest: copied, progress: { _ in })
        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: copied), jpegBytes)

        // 2) 文件内容改写后大小/修改时间变化 → 版本核对失败，拒绝返回旧图或新图
        let tampered = try makeJpeg(width: 200, height: 200, color: .red)
        try tampered.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(modifiedMs) / 1000 + 10)], ofItemAtPath: fileURL.path)

        let staleThumb = await iosReader.thumb(mediaId: folderMediaId, sourceVersion: recordedVersion, isVideo: false, maxPx: 64)
        XCTAssertNil(staleThumb, "目录内文件已被替换，版本不一致必须当未命中回退远端")
        let staleDest = tempDir.appendingPathComponent("stale.jpg")
        let staleCopy = await iosReader.copy(mediaId: folderMediaId, sourceVersion: recordedVersion, isVideo: false, dest: staleDest, progress: { _ in })
        XCTAssertFalse(staleCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDest.path), "核对失败不留半截文件")

        // 3) 目录源视频：首帧缩略图与原片导出
        let videoURL = folderRoot.appendingPathComponent("sub/CLIP_0002.mov")
        try await writeRealTinyMov(to: videoURL)
        let videoOpaque = registry.opaqueId(sourceId: sourceId, relativePath: "sub/CLIP_0002.mov")
        let folderVideoId = "folder:\(sourceId):\(videoOpaque)"
        let vValues = try videoURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let vModifiedMs = try XCTUnwrap(vValues.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) })
        let vSize = Int64(try XCTUnwrap(vValues.fileSize))
        let vVersion = FolderMediaSource.sourceVersion(modifiedAtMs: vModifiedMs, sizeBytes: vSize)

        let rawVThumb = await iosReader.thumb(mediaId: folderVideoId, sourceVersion: vVersion, isVideo: true, maxPx: 64)
        let vThumb = try XCTUnwrap(rawVThumb)
        XCTAssertLessThanOrEqual(max(vThumb.size.width * vThumb.scale, vThumb.size.height * vThumb.scale), 64.5)
        let copiedVideo = tempDir.appendingPathComponent("copied.mov")
        let copiedVideoOk = await iosReader.copy(mediaId: folderVideoId, sourceVersion: vVersion, isVideo: true, dest: copiedVideo, progress: { _ in })
        XCTAssertTrue(copiedVideoOk)
        XCTAssertEqual(try Data(contentsOf: copiedVideo), try Data(contentsOf: videoURL))
    }

    // MARK: - ③ 安全边界：mediaId / localIdentifier / 本地路径绝不出现在上行请求或日志中

    func test_media_id_and_local_path_never_leak_to_uplink_or_logs() async throws {
        let secretMediaId = "F9A12345-SECRET-LOCAL-ID/L0/001"
        let secretFolderId = "folder:secret-source-uuid:secret-opaque-uuid"
        let remoteJpeg = try makeJpeg(width: 16, height: 16)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: remoteJpeg)
        let logs = LogCapture()

        // 让本机读取失败，强制触发回退上行，检验回退时也不会把本机标识带到线上或日志里
        let reader = FakeLocalReader(expectedVersion: "mismatch", thumbImage: nil, copyBytes: nil)
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: secretMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion),
            (mediaId: secretFolderId, hash: videoHash, state: .confirmed, sourceMissing: false, sourceVersion: "1700000000:128"),
        ]))
        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: ticket, ticket: ticket, dest: dest, progress: progress)
            },
            logger: logs,
            localOriginals: LocalFirstOriginals(reader: reader, loadIndex: { index })
        )

        _ = try await timeline.thumbnail(item(hash: photoHash, isMine: true), large: false)
        let url = try await timeline.original(item(hash: photoHash, isMine: true), progress: { _ in })
        LiveTimeline.discardShared(url)

        // #1940：目录源视频同样强制回退远端，覆盖视频上行路径也不带 folder mediaId / 本地路径。
        // 视频走远端 original 需要正数 bytes（与 fake fetchBlob 写出的字节数一致），否则会被 unknownSize 提前挡下。
        let videoItem = item(hash: videoHash, isVideo: true, bytes: Int64(remoteJpeg.count), isMine: true)
        _ = try await timeline.thumbnail(videoItem, large: false)
        let videoURL = try await timeline.original(videoItem, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: videoURL), remoteJpeg, "视频同走远端回退且拿回内容")

        let allWire = remoteSpy.wirePayloads.joined(separator: "\n")
        XCTAssertFalse(allWire.contains(secretMediaId), "PHAsset localIdentifier 绝不能出现在上行报文里")
        XCTAssertFalse(allWire.contains("SECRET-LOCAL-ID"))
        XCTAssertFalse(allWire.contains(secretFolderId), "folder mediaId 绝不能出现在上行报文里")
        XCTAssertFalse(allWire.contains("folder:"))

        let allLogs = logs.all.joined(separator: "\n")
        XCTAssertFalse(allLogs.contains(secretMediaId), "localIdentifier 绝不能明文进日志")
        XCTAssertFalse(allLogs.contains(secretFolderId), "folder mediaId 绝不能进日志")
    }

    // MARK: - 索引去重与重读节奏（5s 空重试 / 60s 刷新）

    func test_duplicate_hash_picks_lexicographically_largest_media_id_and_case_insensitive_lookup() throws {
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: "id-a", hash: photoHash.uppercased(), state: .confirmed, sourceMissing: false, sourceVersion: "v1"),
            (mediaId: "id-z", hash: photoHash.lowercased(), state: .confirmed, sourceMissing: false, sourceVersion: "v2"),
            (mediaId: "id-m", hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: "v3"),
        ]))
        XCTAssertEqual(index.find(photoHash), LocalOriginal(mediaId: "id-z", sourceVersion: "v2"))
        XCTAssertEqual(index.find(photoHash.uppercased()), LocalOriginal(mediaId: "id-z", sourceVersion: "v2"))
    }

    func test_reload_schedule_retries_empty_after_5s_and_refreshes_non_empty_after_60s() throws {
        XCTAssertTrue(localIndexReloadDue(nowMs: 0, loadedAtMs: nil, hasEntries: false))
        XCTAssertFalse(localIndexReloadDue(nowMs: localIndexEmptyRetryMs - 1, loadedAtMs: 0, hasEntries: false))
        XCTAssertTrue(localIndexReloadDue(nowMs: localIndexEmptyRetryMs, loadedAtMs: 0, hasEntries: false))
        XCTAssertFalse(localIndexReloadDue(nowMs: localIndexRefreshMs - 1, loadedAtMs: 0, hasEntries: true))
        XCTAssertTrue(localIndexReloadDue(nowMs: localIndexRefreshMs, loadedAtMs: 0, hasEntries: true))

        var now: Int64 = 1_000
        var loads = 0
        var rows: [Order] = []
        let originals = LocalFirstOriginals(
            reader: FakeLocalReader(),
            loadIndex: { loads += 1; return LocalSourceIndex.of(rows) },
            clock: { now }
        )

        _ = originals.currentIndex()
        _ = originals.currentIndex()
        XCTAssertEqual(loads, 1, "5s 窗口内空索引只读一次")

        now += localIndexEmptyRetryMs
        rows = try seedOrders([(mediaId: photoMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion)])
        _ = originals.currentIndex()
        XCTAssertEqual(loads, 2, "5s 到期后重读并拿到新备份条目")

        now += 10_000
        _ = originals.currentIndex()
        XCTAssertEqual(loads, 2, "非空索引 60s 内不重读")

        now += localIndexRefreshMs
        _ = originals.currentIndex()
        XCTAssertEqual(loads, 3, "60s 到期后刷新")

        // 断开配对或换电脑调用 invalidate() 后，立即触发重读
        originals.invalidate()
        _ = originals.currentIndex()
        XCTAssertEqual(loads, 4, "invalidate 后立即重读")
    }

    // MARK: - ④ (#1937) 取消后快速退出 / 拷贝途中改写必须拒绝

    /// 网格快速滚走：本机缩略图读取因取消返回 nil 时，不再发远端 `thumb.get`（对齐 `original`）。
    /// 反证：删掉 `thumbnail` 里本机读取后的 `Task.checkCancellation()`，远端 thumb.get 次数变 1，本用例红。
    func test_cancelled_local_thumbnail_skips_remote_thumb_get() async throws {
        let remoteJpeg = try makeJpeg(width: 16, height: 16)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: remoteJpeg)
        let gate = AsyncGate()
        let reader = GateReader(gate: gate)
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: photoMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion),
        ]))
        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { [photoHash] ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: photoHash, ticket: ticket, dest: dest, progress: progress)
            },
            logger: LogCapture(),
            localOriginals: LocalFirstOriginals(reader: reader, loadIndex: { index })
        )
        let target = item(hash: photoHash, isMine: true)

        let task = Task { try await timeline.thumbnail(target, large: false) }
        await gate.waitEntered() // 已进入本机读取；取消发生在读取途中
        task.cancel()
        await gate.release()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "取消必须直接抛 CancellationError，实际：\(error)")
        }
        XCTAssertEqual(reader.thumbCalls, 1, "取消前已尝试本机读取")
        XCTAssertEqual(remoteSpy.thumbCalls, 0, "取消后不得再发远端 thumb.get")
    }

    /// 拷后复核前清 `URL` 缓存资源值：拷贝途中源文件被改写（大小不变、修改时间变了）必须判失败。
    /// 反证：去掉 `folderFileVersion` 里的 `removeAllCachedResourceValues()`，拷后复核读到拷贝前缓存的旧修改时间，
    /// 版本比对通过、返回 true，本用例红。
    func test_folder_copy_rejects_source_rewritten_mid_copy_and_leaves_no_partial_file() async throws {
        let logger = LogCapture()
        let registryDir = tempDir.appendingPathComponent("reg-cache", isDirectory: true)
        let folderRoot = tempDir.appendingPathComponent("cache-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        let registry = FolderRegistry(directory: registryDir, logger: logger)
        let sourceId = try registry.addFolder(at: folderRoot, displayName: "CacheFolder")
        let fileURL = folderRoot.appendingPathComponent("changing.jpg")
        let original = try makeJpeg(width: 120, height: 80, color: .systemGreen)
        try original.write(to: fileURL)
        let opaque = registry.opaqueId(sourceId: sourceId, relativePath: "changing.jpg")
        let mediaId = "folder:\(sourceId):\(opaque)"
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedMs = try XCTUnwrap(values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) })
        let recordedVersion = FolderMediaSource.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: Int64(original.count))

        let once = OnceFlag()
        let reader = IOSOriginalReader(folders: registry, logger: logger)
        let dest = tempDir.appendingPathComponent("mid-copy.jpg")
        let ok = await reader.copy(mediaId: mediaId, sourceVersion: recordedVersion, isVideo: false, dest: dest, progress: { _ in
            guard once.take() else { return }
            // 大小不变，只有修改时间变：确保只有拷后复核（而不是拷贝字节数校验）能发现改写。
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(modifiedMs) / 1000 + 10)],
                ofItemAtPath: fileURL.path
            )
        })
        XCTAssertFalse(ok, "拷完复核必须读到最新修改时间并判失败，不能凭 URL 缓存当没变")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "失败不留半截文件")
    }

    func test_photo_access_gate_and_adjustment_digest_alignment() async {
        struct StubAuth: PhotoAuthorizationProviding {
            let level: PhotoAccessLevel
            func currentLevel() -> PhotoAccessLevel { level }
            func requestFullAccess() async -> PhotoAccessLevel { level }
        }

        let logger = LogCapture()
        let registry = FolderRegistry(directory: tempDir.appendingPathComponent("reg-auth", isDirectory: true), logger: logger)
        for blocked in [PhotoAccessLevel.notDetermined, .denied, .restricted] {
            let reader = IOSOriginalReader(folders: registry, logger: logger, auth: StubAuth(level: blocked))
            let t = await reader.thumb(mediaId: photoMediaId, sourceVersion: photoVersion, isVideo: false, maxPx: 256)
            XCTAssertNil(t, "\(blocked) 下不读 PhotoKit，静默返回 nil")
            let dest = tempDir.appendingPathComponent("blocked-\(blocked.rawValue).jpg")
            let ok = await reader.copy(mediaId: photoMediaId, sourceVersion: photoVersion, isVideo: false, dest: dest, progress: { _ in })
            XCTAssertFalse(ok)
        }

        // 校验已编辑照片的 adjustmentDigestHex 与 PPassMedia.originalContent 输出格式一致（16 位小写 hex）
        let digest = IOSOriginalReader.adjustmentDigestHex(of: Data("sample-edit".utf8))
        XCTAssertEqual(digest.count, 16)
        let edited = originalContent(types: [.photo, .adjustmentData, .fullSizePhoto], mediaType: .image, adjustmentDigest: digest, modifiedAtMs: 1_000)
        XCTAssertEqual(edited.version, "5:adj:\(digest)")
        XCTAssertFalse(edited.degraded)
    }

    // MARK: - ⑤ (#1940) 缓存代次隔离 / 并发 .part 隔离 / 无 bytes 本机视频落 shareDir / 单调时钟回拨

    /// 缩略图异步读取途中清空内存缓存：返回给调用方的图照常可用，但不得回填被清空过的 NSCache。
    /// 反证：去掉 `storeIfCurrentGeneration` 的代次核对、无条件 `cache.setObject`，第二次调用直接命中旧缓存，
    /// 本机读取次数停在 1，本用例红。
    func test_clear_memory_cache_during_thumbnail_load_does_not_repopulate_stale_cache() async throws {
        let remoteJpeg = try makeJpeg(width: 16, height: 16)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: remoteJpeg)
        let gate = AsyncGate()
        let localImage = try XCTUnwrap(UIImage(data: makeJpeg(width: 40, height: 30, color: .systemGreen)))
        let reader = GatedThumbReader(gate: gate, image: localImage)
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: photoMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion),
        ]))
        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: ticket, ticket: ticket, dest: dest, progress: progress)
            },
            logger: LogCapture(),
            localOriginals: LocalFirstOriginals(reader: reader, loadIndex: { index })
        )
        let target = item(hash: photoHash, isMine: true)

        let task = Task { try await timeline.thumbnail(target, large: false) }
        await gate.waitEntered()      // 已进入本机读取，尚未返回
        timeline.clearMemoryCache()   // 读取途中清空缓存并推进代次
        await gate.release()

        let first = try await task.value
        XCTAssertEqual(first.size, localImage.size, "清空缓存不影响本次调用方拿到结果")

        _ = try await timeline.thumbnail(target, large: false)
        XCTAssertEqual(reader.thumbCalls, 2, "旧读取结果不得回填已清空的缓存，第二次必须重新走本机读取")
        XCTAssertEqual(remoteSpy.thumbCalls, 0, "两条路径都命中本机，远端 thumb.get 必须为 0")
    }

    /// 同一视频两个并发 `original` 请求：各自的 `.part` 暂存必须同时存在、互不删除，两路均成功返回。
    /// 反证：暂存文件改回以 `item.id` 开头，第二路的 `completeCached(hasPrefix:)` 会删掉第一路仍在写入的 `.part`，
    /// 两路只剩一份暂存，`parts.count` 变 1，本用例红。
    func test_concurrent_original_for_same_video_keeps_both_inflight_parts() async throws {
        let remoteJpeg = try makeJpeg(width: 16, height: 16)
        let videoBytes = makeTinyMovHeader(extraBytes: 64)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: videoBytes)
        let gate = StagedFetchGate()

        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { [videoHash] _, dest, progress in
                try videoBytes.write(to: dest) // 各自写进独立的 inflight-*.part
                _ = await gate.arrive()        // 写完先停住，让两路暂存同时在盘
                progress(UInt64(videoBytes.count))
                return videoHash
            },
            logger: LogCapture(),
            freeBytes: { Int64.max },
            localOriginals: nil
        )
        let target = item(hash: videoHash, isVideo: true, bytes: Int64(videoBytes.count), isMine: false)

        let first = Task { try await timeline.original(target, progress: { _ in }) }
        await gate.waitFirstWritten()      // 第一路已写出暂存并挂起
        let second = Task { try await timeline.original(target, progress: { _ in }) }
        await gate.waitBothWritten()       // 第二路写出暂存，两路同时在途

        let parts = ((try? FileManager.default.contentsOfDirectory(at: LiveTimeline.videoCacheDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "part" }
        XCTAssertEqual(parts.count, 2, "两个并发请求各自的 .part 暂存必须同时存在，不能被对方误删")
        XCTAssertEqual(Set(parts.map(\.lastPathComponent)).count, 2, "两路暂存文件名必须互不相同")

        await gate.release(0)
        let url1 = try await first.value
        await gate.release(1)
        let url2 = try await second.value

        XCTAssertEqual(try Data(contentsOf: url1), videoBytes, "第一路成功返回")
        XCTAssertEqual(try Data(contentsOf: url2), videoBytes, "第二路成功返回")
        XCTAssertEqual(remoteSpy.fetchBlobCalls, 0, "自定义 fetchBlob 桩，未走 spy")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(at: LiveTimeline.videoCacheDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "part" }
        XCTAssertTrue(leftovers.isEmpty, "完成后不留 .part 暂存")
    }

    /// 本机视频没有正数 `bytes`：落即用即清的 `shareDir`，且下一次调用不会把它当缓存残留误删报错。
    /// 反证：本机视频一律落 `videoCacheDir` 时，第二次 `completeCached(item, in:)` 因 `bytes == nil` 把文件当残留删掉，
    /// 随后本机文件已不在、远端又因 `unknownSize` 抛错，本用例红。
    func test_local_video_without_bytes_lands_in_share_dir_and_survives_next_call() async throws {
        let remoteJpeg = try makeJpeg(width: 16, height: 16)
        let videoBytes = makeTinyMovHeader(extraBytes: 64)
        let remoteSpy = RemoteSpy(remoteJpeg: remoteJpeg, remoteBlob: videoBytes)
        let reader = FakeLocalReader(copyBytes: videoBytes)
        let index = LocalSourceIndex.of(try seedOrders([
            (mediaId: "VIDEO-LOCAL-ID/L0/002", hash: videoHash, state: .confirmed, sourceMissing: false, sourceVersion: videoVersion),
        ]))
        let timeline = LiveTimeline(
            client: { ProtoClient(transport: remoteSpy) },
            myNodeId: { "me" },
            fetchBlob: { ticket, dest, progress in
                try await remoteSpy.fetchBlob(hash: ticket, ticket: ticket, dest: dest, progress: progress)
            },
            logger: LogCapture(),
            freeBytes: { 0 }, // 远端视频下载会被 noRoom 挡住，本机命中则不经远端预检
            localOriginals: LocalFirstOriginals(reader: reader, loadIndex: { index })
        )
        let target = item(hash: videoHash, isVideo: true, bytes: nil, isMine: true)

        let url1 = try await timeline.original(target, progress: { _ in })
        XCTAssertEqual(url1.deletingLastPathComponent().standardizedFileURL.path,
                       LiveTimeline.shareDir.standardizedFileURL.path,
                       "无正数 bytes 的本机视频必须落 shareDir，不长期占视频缓存")
        XCTAssertEqual(try Data(contentsOf: url1), videoBytes)
        XCTAssertEqual(url1.pathExtension, "mov")

        let url2 = try await timeline.original(target, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: url2), videoBytes, "第二次调用照常命中本机，不被误清报错")
        XCTAssertEqual(remoteSpy.ticketCalls, 0, "本机命中，不问电脑要票据")
        XCTAssertEqual(remoteSpy.fetchBlobCalls, 0, "本机命中，不走远端下载")
    }

    /// 注入时钟发生回拨时 `localIndexReloadDue` 必须判到期，避免索引卡死不再刷新；默认时钟用单调时钟能正常加载。
    func test_reload_due_when_clock_rewinds_and_default_monotonic_clock_loads() throws {
        XCTAssertTrue(localIndexReloadDue(nowMs: 500, loadedAtMs: 1_000, hasEntries: true), "时钟回拨必须判到期")
        XCTAssertTrue(localIndexReloadDue(nowMs: 0, loadedAtMs: 1_000, hasEntries: false), "空索引回拨同样判到期")

        var loads = 0
        let rows = try seedOrders([
            (mediaId: photoMediaId, hash: photoHash, state: .confirmed, sourceMissing: false, sourceVersion: photoVersion),
        ])
        // 不传 clock → 走默认单调时钟；连续两次在 60s 窗口内只读一次。
        let originals = LocalFirstOriginals(reader: FakeLocalReader(), loadIndex: { loads += 1; return LocalSourceIndex.of(rows) })
        XCTAssertNotNil(originals.currentIndex().find(photoHash), "默认单调时钟能正常加载索引")
        _ = originals.currentIndex()
        XCTAssertEqual(loads, 1, "默认单调时钟下，60s 窗口内非空索引只读一次")
    }
}

/// #1937 测试用：让「本机读取在进行中」与「外部取消」两件事有确定的先后顺序。
private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters = []
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters = []
        waiters.forEach { $0.resume() }
    }
}

/// 本机读取一进入就停住，等测试取消任务后再返回 nil（模拟网格滚走后读取被取消）。
private final class GateReader: LocalOriginalReading, @unchecked Sendable {
    private let gate: AsyncGate
    private let lock = NSLock()
    private var _thumbCalls = 0

    init(gate: AsyncGate) { self.gate = gate }
    var thumbCalls: Int { lock.lock(); defer { lock.unlock() }; return _thumbCalls }

    func thumb(mediaId: String, sourceVersion: String, isVideo: Bool, maxPx: Int) async -> UIImage? {
        lock.lock(); _thumbCalls += 1; lock.unlock()
        await gate.enter()
        return nil
    }

    func copy(mediaId: String, sourceVersion: String, isVideo: Bool, dest: URL,
              progress: @escaping @Sendable (Double) -> Void) async -> Bool { false }
}

/// 只放行第一次的标记（拷贝进度回调里只改写一次源文件）。
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// #1940：本机缩略图读入后停住，等测试在读取途中清空缓存，再返回一张真实图片。
private final class GatedThumbReader: LocalOriginalReading, @unchecked Sendable {
    private let gate: AsyncGate
    private let image: UIImage
    private let lock = NSLock()
    private var _thumbCalls = 0

    init(gate: AsyncGate, image: UIImage) {
        self.gate = gate
        self.image = image
    }

    var thumbCalls: Int { lock.lock(); defer { lock.unlock() }; return _thumbCalls }

    func thumb(mediaId: String, sourceVersion: String, isVideo: Bool, maxPx: Int) async -> UIImage? {
        lock.lock(); _thumbCalls += 1; lock.unlock()
        await gate.enter()
        return image
    }

    func copy(mediaId: String, sourceVersion: String, isVideo: Bool, dest: URL,
              progress: @escaping @Sendable (Double) -> Void) async -> Bool { false }
}

/// #1940：让两路并发取回按「先后写出暂存 → 两路都到齐 → 逐路放行」的确定性顺序推进，
/// 用于验证两路 `inflight-*.part` 在盘上同时存在且互不删除。
private actor StagedFetchGate {
    private var nextIndex = 0
    private var arrived = 0
    private var firstWaiter: CheckedContinuation<Void, Never>?
    private var bothWaiter: CheckedContinuation<Void, Never>?
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedIndexes = Set<Int>()

    /// 登记一次写入并返回本次序号（0 = 先启动的那一路）。阻塞到测试 `release(该序号)`。
    func arrive() async -> Int {
        let idx = nextIndex
        nextIndex += 1
        arrived += 1
        if let w = firstWaiter { firstWaiter = nil; w.resume() }
        if arrived >= 2, let w = bothWaiter { bothWaiter = nil; w.resume() }
        if releasedIndexes.contains(idx) { return idx }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pending[idx] = cont
        }
        return idx
    }

    func waitFirstWritten() async {
        if arrived >= 1 { return }
        await withCheckedContinuation { firstWaiter = $0 }
    }

    func waitBothWritten() async {
        if arrived >= 2 { return }
        await withCheckedContinuation { bothWaiter = $0 }
    }

    func release(_ idx: Int) {
        releasedIndexes.insert(idx)
        if let cont = pending.removeValue(forKey: idx) { cont.resume() }
    }
}
