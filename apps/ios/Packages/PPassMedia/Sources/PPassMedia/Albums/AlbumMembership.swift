import Foundation

/// 照片 → 它所属的**可选相册**（``AlbumCatalog`` 口径），每张的相册 id 按 `String` 升序。
///
/// App 用它算范围键（06-ios-variants「一张照片属于多个相册」）：键 = ``key(_:)``，即排序后的相册 id 用换行连接；
/// 不在任何可选相册里（含隐藏项、音频）的照片键为空串。两种算法：
/// - ``all()``：一次拼全表，枚举每个可选相册的全部照片。全量对账本来就要遍历全部，用它。
/// - ``of(_:)``：只算给定的这几张。取件、lookup 用它——不拉统计、不列相册全部内容，与图库大小无关。
///   约束是与 ``all()`` **完全相等**（范围判断必须精确：多判进 = 把用户没选的照片传走，漏判 = 这张永远不备）；
///   AlbumMembershipIT 在真 PhotoKit 上对整个图库逐张、整批核对相等。
public struct AlbumMembership {
    private let library: PhotoLibraryReading

    public init(library: PhotoLibraryReading) {
        self.library = library
    }

    /// 全图库：assetId → 所属可选相册（升序）。不在任何可选相册里的照片不出现。
    public func all() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for album in AlbumCatalog(library: library).listAlbums() {
            for id in library.assetIdentifiers(inCollection: album.id) ?? [] { out[id, default: []].append(album.id) }
        }
        for key in out.keys { out[key]?.sort() }
        return out
    }

    /// 只算 [assetIds] 这几张：assetId → 所属可选相册（升序）。不在任何可选相册里的照片不出现（与 ``all()`` 一致）。
    ///
    /// 两条路（对齐 Immich `buildAssetAlbumsMap`：逐个相册 `fetchAssets(in:)` + `localIdentifier IN` 谓词）：
    /// - 智能相册（最近项目、个人收藏、视频……）与同步 / 导入相册：逐个集合带谓词精确查「这几张里哪些在你这儿」，
    ///   与 ``all()`` 同一套 options。智能相册不能反查：`fetchAssetCollectionsContaining` 对它们一律返回空（实测）；
    ///   同步 / 导入相册模拟器造不出来、反查未经实测，也走精确查询。
    /// - 普通用户相册（`albumRegular`，含文件夹里的）：PhotoKit 反查（`fetchAssetCollectionsContaining(.album)`），
    ///   先按同一口径筛掉隐藏项与音频。每张一次、与相册个数无关；实测比逐个相册带谓词查快（见 AlbumMembershipIT 计时），
    ///   且与全表逐张相等。
    public func of(_ assetIds: [String]) -> [String: [String]] {
        guard !assetIds.isEmpty else { return [:] }
        var out: [String: [String]] = [:]
        var regular = Set<String>()
        for collection in AlbumCatalog(library: library).selectableCollections() {
            if Self.trustsReverseLookup(collection) {
                regular.insert(collection.id)
                continue
            }
            for id in library.assetIdentifiers(inCollection: collection.id, among: assetIds) ?? [] {
                out[id, default: []].append(collection.id)
            }
        }
        if !regular.isEmpty {
            for (id, albums) in library.userAlbumIdentifiers(containing: assetIds) {
                out[id, default: []].append(contentsOf: albums.filter { regular.contains($0) })
            }
        }
        for key in out.keys { out[key]?.sort() }
        return out.filter { !$0.value.isEmpty }
    }

    /// 哪些集合按反查算：只有普通用户相册（真库实测反查准确）。其余一律逐个精确查。
    static func trustsReverseLookup(_ collection: LibraryCollection) -> Bool {
        collection.type == .album && collection.subtype == .albumRegular
    }

    /// 范围键：所属相册 id（已排序）用换行连接；没有所属相册时为空串。
    public static func key(_ albums: [String]?) -> String {
        (albums ?? []).joined(separator: "\n")
    }
}
