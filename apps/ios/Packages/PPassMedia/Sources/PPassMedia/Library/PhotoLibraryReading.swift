import Foundation
import Photos

/// 相册库里的一个集合（PhotoKit `PHAssetCollection` 的值类型投影）。
///
/// 不做任何取舍——哪些集合进可选列表由 ``AlbumCatalog`` 决定，这样取舍规则能脱离真库用 fake 测。
public struct LibraryCollection: Equatable, Sendable {
    /// `PHAssetCollection.localIdentifier`。同一台设备上稳定；跨设备 / 重装后不保证（见 README 差异 ④）。
    public let id: String
    /// `localizedTitle` 原样：智能相册由系统按 App 的本地化给出；用户相册是用户起的名字，可能为 nil 或空串。
    public let title: String?
    public let type: PHAssetCollectionType
    public let subtype: PHAssetCollectionSubtype

    public init(id: String, title: String?, type: PHAssetCollectionType, subtype: PHAssetCollectionSubtype) {
        self.id = id
        self.title = title
        self.type = type
        self.subtype = subtype
    }
}

/// 一个集合里「照片 + 视频」的统计（不含隐藏项、不含音频）。
public struct CollectionSummary: Equatable, Sendable {
    public let imageCount: Int
    public let videoCount: Int
    /// 按 `creationDate` 降序的第一项；集合为空时为 nil。
    public let newestAssetId: String?

    public var count: Int { imageCount + videoCount }

    public init(imageCount: Int, videoCount: Int, newestAssetId: String?) {
        self.imageCount = imageCount
        self.videoCount = videoCount
        self.newestAssetId = newestAssetId
    }
}

/// 相册枚举需要的只读能力。生产实现是 ``PhotoKitLibrary``；单测用 fake。
///
/// 口径（实现必须遵守，``PhotoKitLibrary`` 的集成测试逐条钉住）：
/// - 只算图片与视频（`PHAssetMediaType.image` / `.video`），音频不算。
/// - 隐藏项（`isHidden`）不算——它们只该出现在「已隐藏」里，而「已隐藏」不可选。
public protocol PhotoLibraryReading {
    /// 全部用户相册与智能相册，**不过滤**，顺序 = PhotoKit 返回的顺序（用户相册即「照片」App 里的顺序）。
    func collections() -> [LibraryCollection]

    /// 某个集合的统计；集合已不存在时返回 nil。
    func summary(ofCollection id: String) -> CollectionSummary?

    /// 某个集合里全部照片与视频的 `localIdentifier`；集合已不存在时返回 nil。
    func assetIdentifiers(inCollection id: String) -> [String]?

    /// 同上，但只看 [assetIds] 这几张：返回其中在这个集合里的那些（口径相同，顺序不保证）；集合已不存在时返回 nil。
    /// 按张判断所属相册用（``AlbumMembership/of(_:)``），查询量与集合大小无关。
    func assetIdentifiers(inCollection id: String, among assetIds: [String]) -> [String]?

    /// 反查：[assetIds] 里每张（只算图片与视频、非隐藏）所在的**用户相册**（`PHAssetCollectionType.album`，任意子类型、
    /// 含文件夹里的）id。不含智能相册——PhotoKit 的反查对智能相册一律返回空（AlbumMembershipIT 实测）。
    /// 口径外的照片（隐藏、音频、已不在图库）不出现在结果里。
    func userAlbumIdentifiers(containing assetIds: [String]) -> [String: [String]]
}
