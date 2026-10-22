import CryptoKit
import Foundation
import Photos

/// 备份的那一份原图资源与它的「内容版本」（refs #968、#1016）。
///
/// Android 的版本 = `dateModified:size`，两个量都只随文件内容变。PhotoKit 的 `PHAsset.modificationDate` 不是：
/// 收藏 / 取消收藏会推进它（模拟器实测），在 Mac 上把照片加进相册、同步到手机后也会推进它（真机实测，#1016），内容没动。
/// 所以 iOS 的版本**不含修改时间**，只用公开信息描述「实际备份的那份资源」（``selectOriginalResource``）：
/// - 没编辑过：取 `.photo` / `.video`。PhotoKit 的原始资源不可改写，版本 = 「类型:original」，一辈子不变。
/// - 编辑过：取渲染结果 `.fullSizePhoto` / `.fullSizeVideo`，版本 = 「类型:adj:<编辑记录摘要>」。
///   编辑记录（`.adjustmentData` 资源）描述这次编辑做了什么；再编辑会换掉它，还原编辑则渲染资源消失、回到「类型:original」。
/// 收藏、挪相册等元数据变化不影响版本，也就不会重新取原图（iCloud 优化存储下等于整张重下）。
///
/// 不用 `PHAssetResource` 的 `fileSize`：那是非公开 KVC，有审核风险（#1016 决定）。
public struct OriginalContent: Equatable, Sendable {
    /// 选中的资源在 `assetResources(for:)` 里的下标；没有可用资源时为 nil。
    public let resourceIndex: Int?
    public let version: String
    /// 版本没能由公开信息给出（没有资源，或编辑过但编辑记录读不到）。此时版本带修改时间，保守地多取、不漏改；调用方应写日志。
    public let degraded: Bool
}

/// 纯函数：由资源类型、编辑记录摘要算出内容版本。
///
/// - Parameter adjustmentDigest: 编辑记录的摘要；没编辑过时不看；编辑过但读不到时为 nil（降级）。
public func originalContent(types: [PHAssetResourceType], mediaType: PHAssetMediaType, adjustmentDigest: String?, modifiedAtMs: Int64) -> OriginalContent {
    guard let index = selectOriginalResource(types: types, mediaType: mediaType) else {
        return OriginalContent(resourceIndex: nil, version: "-:unknown@\(modifiedAtMs)", degraded: true)
    }
    let type = types[index]
    guard isEditedRender(type) else {
        return OriginalContent(resourceIndex: index, version: "\(type.rawValue):original", degraded: false)
    }
    guard let adjustmentDigest else {
        return OriginalContent(resourceIndex: index, version: "\(type.rawValue):unknown@\(modifiedAtMs)", degraded: true)
    }
    return OriginalContent(resourceIndex: index, version: "\(type.rawValue):adj:\(adjustmentDigest)", degraded: false)
}

/// 选中的资源是不是编辑后的渲染结果（版本要看编辑记录）。
func isEditedRender(_ type: PHAssetResourceType) -> Bool { type == .fullSizePhoto || type == .fullSizeVideo }

/// 编辑记录的摘要：SHA-256 前 16 位 hex。只当版本标记用，不参与去重（去重看内容哈希）。
func adjustmentDigest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
}

/// PhotoKit 读法：快照与 lookup 必须走同一处，否则引擎按版本相等判定会全部判成「版本变了」。
///
/// 编辑过的照片要读一次 `.adjustmentData` 资源（几百字节到几 KB）。按「照片 id + 修改时间」缓存：修改时间不变就不再读；
/// 变了（收藏、挪相册、再编辑都会推进它）重读这份小文件，算出的版本只在真编辑时才变。
/// 允许走网络（iCloud 优化存储下编辑记录也可能不在本机）；调用方只在备份轮内调用（#311 D4）。
public final class OriginalContentReader: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: String] = [:]

    public init() {}

    public func read(_ asset: PHAsset, resources: [PHAssetResource]) async -> OriginalContent {
        let modified = Int64((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000)
        let types = resources.map(\.type)
        var digest: String?
        if let index = selectOriginalResource(types: types, mediaType: asset.mediaType), isEditedRender(types[index]),
           let adjustment = resources.first(where: { $0.type == .adjustmentData }) {
            let key = "\(asset.localIdentifier)|\(modified)"
            if let cached = cached(key) {
                digest = cached
            } else if let data = await Self.readData(adjustment) {
                digest = adjustmentDigest(of: data)
                store(key, digest!)
            }
        }
        return originalContent(types: types, mediaType: asset.mediaType, adjustmentDigest: digest, modifiedAtMs: modified)
    }

    private func cached(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return digests[key]
    }

    private func store(_ key: String, _ digest: String) {
        lock.lock(); defer { lock.unlock() }
        digests[key] = digest
    }

    /// 读一份小资源的全部字节；失败返回 nil（调用方降级并写日志）。
    private static func readData(_ resource: PHAssetResource) async -> Data? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let buffer = DataBuffer()
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                buffer.append(chunk)
            }, completionHandler: { error in
                continuation.resume(returning: error == nil ? buffer.data : nil)
            })
        }
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ chunk: Data) { lock.lock(); _data.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
}
