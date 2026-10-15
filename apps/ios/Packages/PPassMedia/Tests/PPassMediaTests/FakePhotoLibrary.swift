import Foundation
import Photos
@testable import PPassMedia

/// 内存里的相册库。口径与 ``PhotoLibraryReading`` 的约定一致：只算图片与视频、隐藏项不算。
final class FakePhotoLibrary: PhotoLibraryReading {
    struct Asset {
        let id: String
        var mediaType: PHAssetMediaType = .image
        var created: Date = Date(timeIntervalSince1970: 0)
        var hidden: Bool = false
    }

    struct Collection {
        let info: LibraryCollection
        var assetIds: [String]
    }

    var assets: [String: Asset] = [:]
    var collectionList: [Collection] = []
    /// 被问过的集合 id（验证「空范围不发查询」）。
    private(set) var queried: [String] = []
    /// 模拟「列表构造中途相册被删」：summary 对这些 id 返回 nil。
    var vanished: Set<String> = []

    func add(_ asset: Asset) { assets[asset.id] = asset }

    @discardableResult
    func addCollection(
        _ id: String, title: String?, type: PHAssetCollectionType = .album,
        subtype: PHAssetCollectionSubtype = .albumRegular, assets: [String] = []
    ) -> LibraryCollection {
        let info = LibraryCollection(id: id, title: title, type: type, subtype: subtype)
        collectionList.append(Collection(info: info, assetIds: assets))
        return info
    }

    func collections() -> [LibraryCollection] { collectionList.map(\.info) }

    func summary(ofCollection id: String) -> CollectionSummary? {
        queried.append(id)
        guard !vanished.contains(id), let members = visibleMembers(id) else { return nil }
        return CollectionSummary(
            imageCount: members.filter { $0.mediaType == .image }.count,
            videoCount: members.filter { $0.mediaType == .video }.count,
            newestAssetId: members.max(by: { $0.created < $1.created })?.id
        )
    }

    func assetIdentifiers(inCollection id: String) -> [String]? {
        queried.append(id)
        return visibleMembers(id)?.map(\.id)
    }

    func assetIdentifiers(inCollection id: String, among assetIds: [String]) -> [String]? {
        queried.append(id)
        let wanted = Set(assetIds)
        return visibleMembers(id)?.map(\.id).filter { wanted.contains($0) }
    }

    /// 模拟 PhotoKit 反查：只答用户相册（智能相册反查不到，与真库实测一致）。
    private(set) var containingCalls = 0

    func userAlbumIdentifiers(containing assetIds: [String]) -> [String: [String]] {
        containingCalls += 1
        var out: [String: [String]] = [:]
        for id in assetIds {
            guard let a = assets[id], !a.hidden, a.mediaType == .image || a.mediaType == .video else { continue }
            out[id] = collectionList.filter { $0.info.type == .album && $0.assetIds.contains(id) }
                .map(\.info.id)
        }
        return out
    }

    private func visibleMembers(_ id: String) -> [Asset]? {
        guard let collection = collectionList.first(where: { $0.info.id == id }) else { return nil }
        return collection.assetIds.compactMap { assets[$0] }
            .filter { !$0.hidden && ($0.mediaType == .image || $0.mediaType == .video) }
    }
}
