import Foundation
import Photos

/// ``PhotoLibraryReading`` 的 PhotoKit 实现。薄层：只做查询与投影，不做取舍。
///
/// 所有查询都是同步的 PhotoKit fetch（`PHFetchResult` 惰性加载，内存与相册规模无关）；
/// 调用方别在主线程上对大库做 ``assetIdentifiers(inCollection:)``。
public struct PhotoKitLibrary: PhotoLibraryReading {
    public init() {}

    public func collections() -> [LibraryCollection] {
        var out: [LibraryCollection] = []
        // 顺序：智能相册在前、用户相册在后；AlbumCatalog 自己重排，这里只保证同类内部是 PhotoKit 的顺序。
        for type in [PHAssetCollectionType.smartAlbum, .album] {
            let result = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            result.enumerateObjects { collection, _, _ in
                out.append(LibraryCollection(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle,
                    type: collection.assetCollectionType,
                    subtype: collection.assetCollectionSubtype
                ))
            }
        }
        return out
    }

    public func summary(ofCollection id: String) -> CollectionSummary? {
        guard let collection = Self.collection(id) else { return nil }
        let newest = PHAsset.fetchAssets(in: collection, options: Self.mediaOptions(newestFirst: true, limit: 1))
        return CollectionSummary(
            imageCount: PHAsset.fetchAssets(in: collection, options: Self.mediaOptions(only: .image)).count,
            videoCount: PHAsset.fetchAssets(in: collection, options: Self.mediaOptions(only: .video)).count,
            newestAssetId: newest.firstObject?.localIdentifier
        )
    }

    public func assetIdentifiers(inCollection id: String) -> [String]? {
        guard let collection = Self.collection(id) else { return nil }
        let result = PHAsset.fetchAssets(in: collection, options: Self.mediaOptions())
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    static func collection(_ id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// 照片 + 视频、不含隐藏项。`includeHiddenAssets` 默认就是 false，这里显式写出来，口径不靠默认值。
    static func mediaOptions(only type: PHAssetMediaType? = nil, newestFirst: Bool = false, limit: Int = 0) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        if let type {
            options.predicate = NSPredicate(format: "mediaType == %d", type.rawValue)
        } else {
            options.predicate = NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        }
        if newestFirst {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        options.fetchLimit = limit
        return options
    }
}
