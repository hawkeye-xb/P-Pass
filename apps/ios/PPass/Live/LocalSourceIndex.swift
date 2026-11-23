// 卡 #1935：对齐 Android #124（MOB-73），查看本机已备份的照片/视频时优先读本机相册与文件夹原图。
//
// 方案「丙」（产品负责人 2026-11-12 / 2026-11-20 定）：只经 `OrderStore.currentOrders()` 只读接口
// 把「当前行、CONFIRMED、有 contentHash、!sourceMissing」的条目读进内存，构建
// `contentHash -> LocalOriginal(mediaId, sourceVersion)` 映射；不落盘、不改账本、不碰核心路径。
//
// 安全硬约束：`mediaId` / `PHAsset.localIdentifier` / 本地文件路径只在本层内部使用，
// 绝不传给任何发往电脑的上行请求或写入日志。
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Photos
import PPassCore
import PPassMedia
import UIKit

/// 账本里一条可用的本机原图：媒体标识（相册 `localIdentifier` 或 `folder:<sourceId>:<opaque>`）+ 入账时的内容版本。
struct LocalOriginal: Equatable, Sendable {
    let mediaId: String
    let sourceVersion: String
}

/// 内容指纹（小写 64-hex BLAKE3） → 本机原图。`empty` = 没有可用的本机来源，一律走远端。
struct LocalSourceIndex: Sendable {
    static let empty = LocalSourceIndex(byHash: [:])

    private let byHash: [String: LocalOriginal]

    var hasEntries: Bool { !byHash.isEmpty }

    func find(_ hash: String) -> LocalOriginal? {
        byHash[hash.lowercased()]
    }

    /// 只收「已确认、有非空内容指纹、原图未标缺失」的当前行。
    /// 同一个指纹对应多条 `mediaId` 时，按 `MediaOrder.precedes`（UTF-8 字节序）取最大的那条，保证结果确定；
    /// 具体能否读取仍须通过 `LocalOriginalReading` 的版本核对，核对不上只会回退远端，绝不串图。
    static func of(_ orders: [Order]) -> LocalSourceIndex {
        var out: [String: LocalOriginal] = [:]
        for order in orders {
            accumulate(&out, order)
        }
        return out.isEmpty ? .empty : LocalSourceIndex(byHash: out)
    }

    /// 经 `OrderStore.currentOrders()` 分页只读构建快照；读失败返回空索引，下次按 5 秒节奏重试。
    static func read(from store: OrderStore) -> LocalSourceIndex {
        do {
            let cursor = try store.currentOrders().cursor()
            var out: [String: LocalOriginal] = [:]
            while let order = try cursor.next() {
                accumulate(&out, order)
            }
            return out.isEmpty ? .empty : LocalSourceIndex(byHash: out)
        } catch {
            return .empty
        }
    }

    private static func accumulate(_ out: inout [String: LocalOriginal], _ order: Order) {
        guard order.state == .confirmed, !order.sourceMissing, !order.sourceVersion.isEmpty else { return }
        guard let rawHash = order.contentHash?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHash.isEmpty else { return }
        let key = rawHash.lowercased()
        if let seen = out[key], !MediaOrder.precedes(seen.mediaId, order.mediaId) {
            return
        }
        out[key] = LocalOriginal(mediaId: order.mediaId, sourceVersion: order.sourceVersion)
    }
}

/// 空索引（账本刚初始化 / 尚未备份完成）隔 5 秒重读一次。
let localIndexEmptyRetryMs: Int64 = 5_000

/// 有内容时隔 60 秒重读一次（新备份的照片进映射；旧条目过期只会在版本核对时回退远端）。
let localIndexRefreshMs: Int64 = 60_000

/// `loadedAtMs == nil` 表示尚未读过。纯函数。
func localIndexReloadDue(nowMs: Int64, loadedAtMs: Int64?, hasEntries: Bool) -> Bool {
    guard let loadedAtMs else { return true }
    // #1940：注入的时钟若发生回拨（nowMs 落后于上次加载时刻），窗口差值恒为负、永远到不了期，索引会卡死不再刷新；
    // 直接判到期，立即重读一次。单调时钟本身不会回拨，这里兜住测试注入或异常时钟。
    if nowMs < loadedAtMs { return true }
    let window = hasEntries ? localIndexRefreshMs : localIndexEmptyRetryMs
    return nowMs - loadedAtMs >= window
}

/// 打开本机媒体标识、核对版本、读出缩略图或复制原图。
protocol LocalOriginalReading: Sendable {
    /// 核对一致 → 原图解码出的缩略图（像素长边不超过 `maxPx`）；读不到 / 核对不上 / 仅在 iCloud → nil。
    func thumb(mediaId: String, sourceVersion: String, isVideo: Bool, maxPx: Int) async -> UIImage?
    /// 核对一致 → 把原图复制到 `dest`；读不到 / 核对不上 / 仅在 iCloud → false（不留下半截文件）。
    func copy(mediaId: String, sourceVersion: String, isVideo: Bool, dest: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool
}

/// 丙案的内存映射 + 本机读取：索引按 `localIndexReloadDue` 节奏从账本重读，命中后交给 `reader` 核对版本并读取。
final class LocalFirstOriginals: @unchecked Sendable {
    private let reader: LocalOriginalReading
    private let loadIndex: @Sendable () -> LocalSourceIndex
    private let clock: @Sendable () -> Int64
    private let lock = NSLock()
    private var index: LocalSourceIndex = .empty
    private var loadedAtMs: Int64?

    init(reader: LocalOriginalReading,
         loadIndex: @escaping @Sendable () -> LocalSourceIndex,
         clock: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }) {
        self.reader = reader
        self.loadIndex = loadIndex
        self.clock = clock
    }

    func currentIndex() -> LocalSourceIndex {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if localIndexReloadDue(nowMs: now, loadedAtMs: loadedAtMs, hasEntries: index.hasEntries) {
            index = loadIndex()
            loadedAtMs = now
        }
        return index
    }

    /// 断开配对或换电脑时清空内存快照，避免沿用旧账映射。
    func invalidate() {
        lock.lock()
        index = .empty
        loadedAtMs = nil
        lock.unlock()
    }

    func thumb(hash: String, isVideo: Bool, maxPx: Int) async -> UIImage? {
        guard let hit = currentIndex().find(hash) else { return nil }
        return await reader.thumb(mediaId: hit.mediaId, sourceVersion: hit.sourceVersion, isVideo: isVideo, maxPx: maxPx)
    }

    func copy(hash: String, isVideo: Bool, dest: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        guard let hit = currentIndex().find(hash) else { return false }
        return await reader.copy(mediaId: hit.mediaId, sourceVersion: hit.sourceVersion, isVideo: isVideo, dest: dest, progress: progress)
    }
}

/// iOS 真实现：支持 PhotoKit `PHAsset`（`isNetworkAccessAllowed = false`，绝不触发 iCloud 下载或权限弹窗）
/// 与已授权目录源 `folder:<sourceId>:<opaque>`（根书签安全作用域 + 文件协调读取）。
final class IOSOriginalReader: LocalOriginalReading, @unchecked Sendable {
    private let folders: FolderRegistry
    private let logger: CoreLogger
    private let auth: PhotoAuthorizationProviding

    init(folders: FolderRegistry, logger: CoreLogger, auth: PhotoAuthorizationProviding = PhotoKitAuthorization()) {
        self.folders = folders
        self.logger = logger
        self.auth = auth
    }

    func thumb(mediaId: String, sourceVersion: String, isVideo: Bool, maxPx: Int) async -> UIImage? {
        guard maxPx > 0, !sourceVersion.isEmpty else { return nil }
        if let folder = Self.parseFolderMediaId(mediaId) {
            return await folderThumb(sourceId: folder.sourceId, opaqueId: folder.opaqueId,
                                     expectedVersion: sourceVersion, isVideo: isVideo, maxPx: maxPx)
        }
        return await photoThumb(mediaId: mediaId, expectedVersion: sourceVersion, maxPx: maxPx)
    }

    func copy(mediaId: String, sourceVersion: String, isVideo: Bool, dest: URL,
              progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        guard !sourceVersion.isEmpty else { return false }
        let ok: Bool
        if let folder = Self.parseFolderMediaId(mediaId) {
            ok = await folderCopy(sourceId: folder.sourceId, opaqueId: folder.opaqueId,
                                  expectedVersion: sourceVersion, dest: dest, progress: progress)
        } else {
            ok = await photoCopy(mediaId: mediaId, expectedVersion: sourceVersion, dest: dest, progress: progress)
        }
        if !ok {
            try? FileManager.default.removeItem(at: dest)
        }
        return ok
    }

    // MARK: - 相册来源（PhotoKit，纯本机离线读取）

    /// 未决定（`.notDetermined`）时绝不触碰 PhotoKit，防止系统自动弹授权框（#1259）；拒绝/受限也直接放弃。
    private var canReadPhotoLibrary: Bool {
        switch auth.currentLevel() {
        case .full, .limited: return true
        case .notDetermined, .denied, .restricted: return false
        }
    }

    /// 打开 `PHAsset` 并离线核对 `sourceVersion`（与 `OriginalContentReader` 同一版本规则，但禁止任何网络请求）。
    private func verifiedPhotoAsset(mediaId: String, expectedVersion: String) async -> (asset: PHAsset, resource: PHAssetResource)? {
        guard canReadPhotoLibrary else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [mediaId], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let types = resources.map(\.type)
        guard let index = selectOriginalResource(types: types, mediaType: asset.mediaType) else { return nil }
        let selected = resources[index]

        var digest: String?
        if selected.type == .fullSizePhoto || selected.type == .fullSizeVideo {
            guard let adjustment = resources.first(where: { $0.type == .adjustmentData }),
                  let data = await Self.readLocalData(of: adjustment) else {
                return nil
            }
            digest = Self.adjustmentDigestHex(of: data)
        }
        let modifiedMs = Int64((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000)
        let content = originalContent(types: types, mediaType: asset.mediaType, adjustmentDigest: digest, modifiedAtMs: modifiedMs)
        guard !content.degraded, content.version == expectedVersion else { return nil }
        return (asset, selected)
    }

    /// 与 `PPassMedia.adjustmentDigest` 完全一致：SHA-256 前 16 位小写 hex。
    static func adjustmentDigestHex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func photoThumb(mediaId: String, expectedVersion: String, maxPx: Int) async -> UIImage? {
        guard !Task.isCancelled, let (asset, selected) = await verifiedPhotoAsset(mediaId: mediaId, expectedVersion: expectedVersion) else {
            return nil
        }
        // 原图仅在 iCloud 时回退远端，避免把低清云端占位缩略图当成 1024 大图塞进缓存。
        guard await PhotoKitOriginalSource.isLocal(selected) == true, !Task.isCancelled else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let size = CGSize(width: maxPx, height: maxPx)
        let box = ImageRequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let reqId = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let hasError = info?[PHImageErrorKey] != nil
                    let valid = (!inCloud && !degraded && !cancelled && !hasError) ? image : nil
                    if box.finish() {
                        continuation.resume(returning: valid)
                    }
                }
                box.setId(reqId)
            }
        } onCancel: {
            if let reqId = box.cancel() {
                PHImageManager.default().cancelImageRequest(reqId)
            }
        }
    }

    private func photoCopy(mediaId: String, expectedVersion: String, dest: URL,
                           progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        guard !Task.isCancelled, let (_, resource) = await verifiedPhotoAsset(mediaId: mediaId, expectedVersion: expectedVersion) else {
            return false
        }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            return false
        }
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        options.progressHandler = { value in progress(min(max(value, 0), 1)) }
        let state = DataStreamBox()
        let ok: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let reqId = manager.requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                    guard state.canWrite else { return }
                    do {
                        try handle.write(contentsOf: chunk)
                    } catch {
                        state.markFailed()
                        if let id = state.requestId { manager.cancelDataRequest(id) }
                    }
                }, completionHandler: { error in
                    try? handle.close()
                    let succeeded = !state.failed && !state.cancelled && error == nil
                    if state.finish() {
                        continuation.resume(returning: succeeded)
                    }
                })
                state.setRequestId(reqId)
            }
        } onCancel: {
            if let reqId = state.cancel() {
                manager.cancelDataRequest(reqId)
            }
        }
        try? handle.close()
        if ok, !Task.isCancelled {
            progress(1.0)
            return true
        }
        return false
    }

    private static func readLocalData(of resource: PHAssetResource) async -> Data? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let buf = LocalDataBuffer()
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                buf.append(chunk)
            }, completionHandler: { error in
                if buf.finish() {
                    continuation.resume(returning: error == nil ? buf.data : nil)
                }
            })
        }
    }

    // MARK: - 目录来源（`folder:<sourceId>:<opaque>`）

    static func parseFolderMediaId(_ mediaId: String) -> (sourceId: String, opaqueId: String)? {
        let prefix = "folder:"
        guard mediaId.hasPrefix(prefix) else { return nil }
        let rest = mediaId.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let sourceId = String(rest[..<colon])
        let opaqueId = String(rest[rest.index(after: colon)...])
        guard !sourceId.isEmpty, !opaqueId.isEmpty else { return nil }
        return (sourceId, opaqueId)
    }

    private func withVerifiedFolderFile<T>(sourceId: String, opaqueId: String, expectedVersion: String,
                                           body: (URL, Int64) throws -> T?) async -> T? {
        guard !Task.isCancelled,
              let relPath = folders.relativePath(sourceId: sourceId, opaqueId: opaqueId),
              let record = folders.record(id: sourceId),
              record.status != FolderMediaSource.pendingScopeStatus,
              let root = try? FolderBookmarks.resolve(record, registry: folders, logger: logger) else {
            return nil
        }
        return try? await FolderBookmarks.withScope(root.url) { rootURL in
            let target = rootURL.appendingPathComponent(relPath)
            var coordError: NSError?
            var output: T?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &coordError) { coordinatedURL in
                guard let (version, size) = Self.folderFileVersion(at: coordinatedURL),
                      version == expectedVersion else {
                    return
                }
                output = try? body(coordinatedURL, size)
            }
            guard coordError == nil else { return nil }
            return output
        }
    }

    private static func folderFileVersion(at url: URL) -> (version: String, sizeBytes: Int64)? {
        // #1937：`URL.resourceValues` 按 URL 实例缓存；`folderCopy` 在同一 NSFileCoordinator 回调里先验一次、
        // 拷完再复核同一个 URL，不复位缓存会读到拷贝前的旧属性。读之前清空，确保拿到当前磁盘属性。
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey
        ]) else {
            return nil
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
        if let head = try? FileHandle(forReadingFrom: url) {
            defer { try? head.close() }
            if let magic = try? head.read(upToCount: 8), magic.count == 8,
               String(decoding: magic, as: UTF8.self).hasPrefix("book") {
                return nil
            }
        }
        let modifiedMs = values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let size = values.fileSize.map(Int64.init) ?? values.totalFileAllocatedSize.map(Int64.init)
        let version = FolderMediaSource.sourceVersion(modifiedAtMs: modifiedMs, sizeBytes: size)
        guard !version.isEmpty, let size else { return nil }
        return (version, size)
    }

    private func folderThumb(sourceId: String, opaqueId: String, expectedVersion: String,
                             isVideo: Bool, maxPx: Int) async -> UIImage? {
        await withVerifiedFolderFile(sourceId: sourceId, opaqueId: opaqueId, expectedVersion: expectedVersion) { url, _ in
            if isVideo {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPx, height: maxPx)
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                return UIImage(cgImage: cgImage)
            }
            let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPx,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }

    private func folderCopy(sourceId: String, opaqueId: String, expectedVersion: String,
                            dest: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let copied = await withVerifiedFolderFile(sourceId: sourceId, opaqueId: opaqueId, expectedVersion: expectedVersion) { url, expectedSize -> Bool? in
            let fm = FileManager.default
            try? fm.removeItem(at: dest)
            guard fm.createFile(atPath: dest.path, contents: nil) else { return nil }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: dest)
            defer { try? output.close() }
            var written: Int64 = 0
            let total = Double(max(expectedSize, 1))
            while !Task.isCancelled {
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(min(Double(written) / total, 1.0))
            }
            guard !Task.isCancelled, written == expectedSize,
                  let after = Self.folderFileVersion(at: url), after.version == expectedVersion else {
                return nil
            }
            try output.close()
            progress(1.0)
            return true
        }
        return copied == true
    }
}

// MARK: - 并发回调安全盒

private final class ImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requestId: PHImageRequestID?
    private var cancelled = false
    private var finished = false

    func setId(_ id: PHImageRequestID) {
        let shouldCancel: Bool = lock.withLock {
            requestId = id
            return cancelled && !finished
        }
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }

    func cancel() -> PHImageRequestID? {
        lock.withLock {
            cancelled = true
            return finished ? nil : requestId
        }
    }

    func finish() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}

private final class DataStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _requestId: PHAssetResourceDataRequestID?
    private var _failed = false
    private var _cancelled = false
    private var _finished = false

    var requestId: PHAssetResourceDataRequestID? { lock.withLock { _requestId } }
    var failed: Bool { lock.withLock { _failed } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var canWrite: Bool { lock.withLock { !_failed && !_cancelled && !_finished } }

    func setRequestId(_ id: PHAssetResourceDataRequestID) {
        let shouldCancel: Bool = lock.withLock {
            _requestId = id
            return (_cancelled || _failed) && !_finished
        }
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func markFailed() { lock.withLock { _failed = true } }

    func cancel() -> PHAssetResourceDataRequestID? {
        lock.withLock {
            _cancelled = true
            return _finished ? nil : _requestId
        }
    }

    func finish() -> Bool {
        lock.withLock {
            guard !_finished else { return false }
            _finished = true
            return true
        }
    }
}

private final class LocalDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    private var _finished = false

    func append(_ chunk: Data) { lock.withLock { _data.append(chunk) } }
    var data: Data { lock.withLock { _data } }

    func finish() -> Bool {
        lock.withLock {
            guard !_finished else { return false }
            _finished = true
            return true
        }
    }
}
