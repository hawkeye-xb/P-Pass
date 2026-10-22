import Foundation
import Photos
import UniformTypeIdentifiers

/// 一张照片的原图资源（`PHAssetResource` 的值类型投影）。
public struct OriginalResourceInfo: Equatable, Sendable {
    public let assetId: String
    /// 资源自带的原始文件名（如 IMG_0001.HEIC）。
    public let originalFilename: String
    public let uniformTypeIdentifier: String
    public let resourceType: PHAssetResourceType

    public init(assetId: String, originalFilename: String, uniformTypeIdentifier: String, resourceType: PHAssetResourceType) {
        self.assetId = assetId
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.resourceType = resourceType
    }

    /// 由 UTI 推出 MIME（给 PPassCore `MediaDetails.mimeType`）；推不出时为 application/octet-stream。
    public var mimeType: String {
        UTType(uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// 选哪一份资源来备份：相册里用户看到的那一张。
///
/// 规则：资产编辑过（带 `.fullSizePhoto` / `.fullSizeVideo` 渲染结果）就取编辑后的渲染结果，否则图片取 `.photo`、视频取 `.video`。
/// 编辑参数（`.adjustmentData`）不取。实况照片只取静态图（编辑过为 `.fullSizePhoto`，否则 `.photo`），配对视频
/// （`.pairedVideo` / `.fullSizePairedVideo`）不取（沿用 MOB-79：跨端实况保真本轮不做）。
/// RAW+JPEG 成对拍摄的照片取 `.photo`（JPEG），RAW 在 `.alternatePhoto` 里，不取。
/// 找不到对应类型的资源时返回 nil，调用方按「资源确实不可得」计入失败。
public func selectOriginalResource(types: [PHAssetResourceType], mediaType: PHAssetMediaType) -> Int? {
    let edited: PHAssetResourceType
    let unedited: PHAssetResourceType
    switch mediaType {
    case .image: (edited, unedited) = (.fullSizePhoto, .photo)
    case .video: (edited, unedited) = (.fullSizeVideo, .video)
    default: return nil
    }
    return types.firstIndex(of: edited) ?? types.firstIndex(of: unedited)
}

/// 原图字节的来源。生产实现是 ``PhotoKitOriginalSource``，单测用 fake。
public protocol OriginalResourceSource: Sendable {
    /// 找到这张照片的原图资源。照片已不存在时抛 ``OriginalFetchFailure/sourceMissing``；
    /// 照片还在、但找不到原图资源时抛 ``OriginalFetchFailure/unavailable(reason:)``。
    func resolveOriginal(assetId: String) throws -> OriginalResourceInfo

    /// 流式读出资源的字节，逐块交给 `chunk`。允许走网络（iCloud）。
    /// `chunk` 抛错时必须停止读取，并把这个错误原样抛出。Task 被取消时必须尽快停止（PhotoKit 实现会调 `cancelDataRequest`）。
    func streamData(
        of resource: OriginalResourceInfo,
        progress: @escaping @Sendable (Double) -> Void,
        chunk: @escaping (Data) throws -> Void
    ) async throws

    /// 这份资源此刻在不在本机（不下载）。true = 本机可读；false = 要从 iCloud 下载；nil = 判断不了。
    func isLocal(_ resource: OriginalResourceInfo) async -> Bool?
}

public extension OriginalResourceSource {
    func isLocal(_ resource: OriginalResourceInfo) async -> Bool? { nil }
}

/// ``OriginalResourceSource`` 的 PhotoKit 实现：`PHAssetResourceManager.requestData`，并设 `isNetworkAccessAllowed = true`。
///
/// 依据 #311 D4：只在备份轮内调用，备份轮本身受 Wi-Fi / 电量约束，这里不另外判断蜂窝网络。
/// 用 `requestData`（按块回调）而不是 `writeData(toFile:)`：边下边写边计数，内存占用与文件大小无关，
/// 而且能在中途因为本地写失败而主动取消。
public struct PhotoKitOriginalSource: OriginalResourceSource {
    public init() {}

    public func resolveOriginal(assetId: String) throws -> OriginalResourceInfo {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            throw OriginalFetchFailure.sourceMissing
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let index = selectOriginalResource(types: resources.map { r in r.type }, mediaType: asset.mediaType) else {
            let types = resources.map { r in String(r.type.rawValue) }.joined(separator: ",")
            throw OriginalFetchFailure.unavailable(reason: "no original resource (mediaType=\(asset.mediaType.rawValue), resourceTypes=[\(types)])")
        }
        let r = resources[index]
        return OriginalResourceInfo(assetId: assetId, originalFilename: r.originalFilename, uniformTypeIdentifier: r.uniformTypeIdentifier, resourceType: r.type)
    }

    public func streamData(
        of resource: OriginalResourceInfo,
        progress: @escaping @Sendable (Double) -> Void,
        chunk: @escaping (Data) throws -> Void
    ) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [resource.assetId], options: nil).firstObject else {
            throw OriginalFetchFailure.sourceMissing
        }
        guard let target = PHAssetResource.assetResources(for: asset).first(where: { r in
            r.type == resource.resourceType && r.originalFilename == resource.originalFilename
        }) else {
            throw OriginalFetchFailure.sourceMissing
        }
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }
        let request = RequestBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = manager.requestData(for: target, options: options, dataReceivedHandler: { data in
                    guard request.chunkError == nil else { return }
                    do {
                        try chunk(data)
                    } catch {
                        request.chunkError = error
                        if let id = request.id { manager.cancelDataRequest(id) }
                    }
                }, completionHandler: { error in
                    if let failure = request.chunkError ?? error {
                        continuation.resume(throwing: failure)
                    } else {
                        continuation.resume()
                    }
                })
                request.id = id
                // 回调可能在拿到请求号之前就来了：那时没法取消，这里补一次。
                if request.cancelled || request.chunkError != nil { manager.cancelDataRequest(id) }
            }
        } onCancel: {
            request.cancelled = true
            if let id = request.id { manager.cancelDataRequest(id) }
        }
    }
}

extension PhotoKitOriginalSource {
    /// 用「不许走网络」读一次：收到第一块数据 = 在本机（随即取消，不读完）；系统报「需要网络」（PHPhotosError 3164）
    /// = 原图在 iCloud。只用公开 API，不触发下载（#337 真机验证过这条判据，#1092 用它决定首页文案）。
    public func isLocal(_ resource: OriginalResourceInfo) async -> Bool? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [resource.assetId], options: nil).firstObject,
              let target = PHAssetResource.assetResources(for: asset).first(where: { r in
                  r.type == resource.resourceType && r.originalFilename == resource.originalFilename
              }) else { return nil }
        return await Self.isLocal(target)
    }

    /// 同上，直接给 `PHAssetResource`。
    public static func isLocal(_ resource: PHAssetResource) async -> Bool? {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let state = LocalityProbeState()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { _ in
                if state.markGotData(), let id = state.id { manager.cancelDataRequest(id) }
            }, completionHandler: { error in
                if state.gotData { continuation.resume(returning: true); return }
                guard let error = error as NSError? else { continuation.resume(returning: true); return } // 空文件
                let networkRequired = error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.networkAccessRequired.rawValue
                continuation.resume(returning: networkRequired ? false : nil)
            })
            state.id = id
            if state.gotData { manager.cancelDataRequest(id) }
        }
    }
}

private final class LocalityProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHAssetResourceDataRequestID?
    private var _gotData = false

    var id: PHAssetResourceDataRequestID? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); _id = newValue; lock.unlock() }
    }
    var gotData: Bool { lock.lock(); defer { lock.unlock() }; return _gotData }

    /// 第一次收到数据时返回 true（只取消一次）。
    func markGotData() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_gotData else { return false }
        _gotData = true
        return true
    }
}

/// requestData 的请求号与中途错误，跨回调线程共享。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHAssetResourceDataRequestID?
    private var _chunkError: Error?
    private var _cancelled = false

    var id: PHAssetResourceDataRequestID? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); _id = newValue; lock.unlock() }
    }
    var chunkError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _chunkError }
        set { lock.lock(); _chunkError = newValue; lock.unlock() }
    }
    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
}
