import Foundation
import Photos

/// 备份的那一份原图资源与它的「内容版本」（refs #968）。
///
/// Android 的版本 = `dateModified:size`，两个量都只随文件内容变。PhotoKit 的 `PHAsset.modificationDate` 不是：
/// 模拟器实测收藏 / 取消收藏会推进它（加进相册不会），内容没动。所以 iOS 的版本**不含修改时间**，只取
/// 实际备份的那份资源（``selectOriginalResource``，编辑过取渲染结果）的「类型:大小」：
/// 编辑、再次编辑、还原编辑都会换资源或改大小，收藏等元数据变化不影响。
/// 大小来自 `PHAssetResource` 的 `fileSize`（KVC，非公开 API，但读的是库里已有的元数据，不读文件、不触发 iCloud 下载）。
///
/// 已知差异（登记于 06-ios-variants）：两次编辑渲染出的字节数恰好相同时会漏掉新版本，Android 靠修改时间不会漏。
public struct OriginalContent: Equatable, Sendable {
    /// 选中的资源在 `assetResources(for:)` 里的下标；没有可用资源时为 nil。
    public let resourceIndex: Int?
    /// 选中资源的大小；读不出来为 nil。
    public let size: Int64?
    public let version: String
    /// 版本没能由「类型:大小」给出（没有资源，或读不到大小）。此时版本带修改时间，保守地多取、不漏改；调用方应写日志。
    public var degraded: Bool { size == nil || resourceIndex == nil }
}

/// 纯函数：由资源类型与大小（一一对应）算出内容版本。
public func originalContent(types: [PHAssetResourceType], sizes: [Int64?], mediaType: PHAssetMediaType, modifiedAtMs: Int64) -> OriginalContent {
    let index = selectOriginalResource(types: types, mediaType: mediaType)
    let size = index.flatMap { sizes.indices.contains($0) ? sizes[$0] : nil }
    let version: String
    if let index, let size {
        version = "\(types[index].rawValue):\(size)"
    } else {
        version = "\(index.map { String(types[$0].rawValue) } ?? "-"):unknown@\(modifiedAtMs)"
    }
    return OriginalContent(resourceIndex: index, size: size, version: version)
}

/// PhotoKit 读法：快照与 lookup 必须走同一处，否则引擎按版本相等判定会全部判成「版本变了」。
public func readOriginalContent(of asset: PHAsset, resources: [PHAssetResource]) -> OriginalContent {
    let modified = Int64((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000)
    return originalContent(
        types: resources.map(\.type),
        sizes: resources.map { ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value },
        mediaType: asset.mediaType, modifiedAtMs: modified)
}
