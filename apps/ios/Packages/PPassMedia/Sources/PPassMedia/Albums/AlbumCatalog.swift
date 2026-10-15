import Foundation
import Photos

/// 可选范围里的一个相册——Android `MediaScanner.Bucket(id, name, count, coverUri)` 的对位物。
///
/// 与 Bucket 的差异逐条登记在包内 README「与 MediaStore 的语义差异」。最要紧的一条：
/// **一张照片可以同时属于多个相册**，所以范围计数不是所选相册 ``count`` 之和，而是 ``AlbumScope`` 算出的并集。
public struct MediaAlbum: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 「最近项目 / Recents」（`smartAlbumUserLibrary`）：整个图库。iOS 上相机拍的照片**只在这里**，
        /// 不在任何用户相册里——Android 有 Camera 这个 bucket 兜住，iOS 没有，所以它必须可选。
        case library
        /// 用户自建相册（以及 iTunes / Finder 同步来的相册、导入相册）。
        case userAlbum
        /// 系统按媒体类型 / 标记归的智能相册（个人收藏、视频、截屏……），白名单见 ``AlbumCatalog/selectableSmartSubtypes``。
        case smartAlbum(PHAssetCollectionSubtype)
    }

    /// `PHAssetCollection.localIdentifier`。Android 的 bucket id 是 Long，这里是 String。
    public let id: String
    /// nil = 系统没给名字或名字为空白；UI 负责本地化成「未命名相册」（对位 Android `bucketNameOrNull`）。
    public let title: String?
    public let kind: Kind
    /// 照片 + 视频，不含隐藏项。是**这个相册自己**的数，不是范围计数。
    public let count: Int
    public let imageCount: Int
    public let videoCount: Int
    /// 封面 = 相册内 `creationDate` 最新的一项（对位 UX-10）；空相册为 nil，UI 退化为空白封面，不阻塞选择。
    public let coverAssetId: String?
}

/// 把图库里的集合整理成「可选范围」列表（对位 `MediaScanner.listBuckets()`）。
///
/// 取舍（README 差异 ② 有理由）：
/// - 收：「最近项目」、用户相册（含空相册——「照片」App 里也列着空相册）、白名单里的智能相册（只列非空的，
///   与「照片」App「媒体类型」一栏只显示有内容的类型一致）。
/// - 不收：「已隐藏」、「最近删除」（PhotoKit 不公开，但若某个系统版本把它枚举出来，白名单也挡得住）、
///   「最近添加」（滚动窗口，选了它范围会随时间自己变）、iCloud 共享相簿与「我的照片流」（内容不是本机图库的原图）、
///   以及白名单外的一切未知子类型。
public struct AlbumCatalog {
    /// 可选的智能相册子类型，顺序即列表里的顺序（对齐「照片」App 的「媒体类型」一栏）。
    /// 用原始值比较而不是 Swift case，`smartAlbumSpatial`（iOS 18）在 iOS 16 上也能编译、只是枚举不到。
    public static let selectableSmartSubtypes: [Int] = [
        PHAssetCollectionSubtype.smartAlbumFavorites.rawValue,       // 203
        PHAssetCollectionSubtype.smartAlbumVideos.rawValue,          // 202
        PHAssetCollectionSubtype.smartAlbumSelfPortraits.rawValue,   // 210
        PHAssetCollectionSubtype.smartAlbumLivePhotos.rawValue,      // 213
        PHAssetCollectionSubtype.smartAlbumDepthEffect.rawValue,     // 212
        PHAssetCollectionSubtype.smartAlbumPanoramas.rawValue,       // 201
        PHAssetCollectionSubtype.smartAlbumTimelapses.rawValue,      // 204
        PHAssetCollectionSubtype.smartAlbumSlomoVideos.rawValue,     // 208
        PHAssetCollectionSubtype.smartAlbumCinematic.rawValue,       // 218
        219,                                                         // smartAlbumSpatial（iOS 18+）
        PHAssetCollectionSubtype.smartAlbumBursts.rawValue,          // 207
        PHAssetCollectionSubtype.smartAlbumScreenshots.rawValue,     // 211
        PHAssetCollectionSubtype.smartAlbumScreenRecordings.rawValue, // 220
        PHAssetCollectionSubtype.smartAlbumAnimated.rawValue,        // 214
        PHAssetCollectionSubtype.smartAlbumLongExposures.rawValue,   // 215
        PHAssetCollectionSubtype.smartAlbumRAW.rawValue,             // 217
    ]

    /// 可选的用户相册子类型。共享相簿（101）与照片流（100）不在内。
    public static let selectableAlbumSubtypes: Set<Int> = [
        PHAssetCollectionSubtype.albumRegular.rawValue,      // 2
        PHAssetCollectionSubtype.albumSyncedEvent.rawValue,  // 3
        PHAssetCollectionSubtype.albumSyncedFaces.rawValue,  // 4
        PHAssetCollectionSubtype.albumSyncedAlbum.rawValue,  // 5
        PHAssetCollectionSubtype.albumImported.rawValue,     // 6
    ]

    private let library: PhotoLibraryReading

    public init(library: PhotoLibraryReading) {
        self.library = library
    }

    /// 可选相册列表：「最近项目」在最前，然后是用户相册（保持「照片」App 里的顺序），最后是非空的智能相册。
    ///
    /// Android 按名字字母序排；iOS 用户相册在「照片」App 里有用户自己拖出来的顺序，跟着它走才「观感一致」。
    public func listAlbums() -> [MediaAlbum] {
        var library: [MediaAlbum] = []
        var userAlbums: [MediaAlbum] = []
        var smartBySubtype: [Int: [MediaAlbum]] = [:]

        for collection in self.library.collections() {
            guard let kind = Self.selectableKind(of: collection),
                  let album = makeAlbum(collection, kind: kind) else { continue }
            switch kind {
            case .library: library.append(album)
            case .userAlbum: userAlbums.append(album)
            case .smartAlbum:
                guard album.count > 0 else { continue }
                smartBySubtype[collection.subtype.rawValue, default: []].append(album)
            }
        }
        let smart = Self.selectableSmartSubtypes.flatMap { smartBySubtype[$0] ?? [] }
        return library + userAlbums + smart
    }

    /// 可选的集合（不算统计、不排序）。与 ``listAlbums()`` 用同一条取舍规则，只少了两件要逐个相册查库的事：
    /// 「智能相册只列非空的」与「构造中途被删的跳过」。按张判断「照片属于哪些可选相册」时这两条自然成立
    /// （照片在里面，相册就非空、就还在），所以 ``AlbumMembership`` 用它，免掉每个相册 3 次 fetch。
    public func selectableCollections() -> [LibraryCollection] {
        library.collections().filter { Self.selectableKind(of: $0) != nil }
    }

    /// 一个集合能不能进可选列表、以什么身份进；nil = 不可选。``listAlbums()`` 与 ``selectableCollections()`` 共用。
    static func selectableKind(of collection: LibraryCollection) -> MediaAlbum.Kind? {
        switch collection.type {
        case .smartAlbum where collection.subtype == .smartAlbumUserLibrary:
            return .library
        case .smartAlbum where selectableSmartSubtypes.contains(collection.subtype.rawValue):
            return .smartAlbum(collection.subtype)
        case .album where selectableAlbumSubtypes.contains(collection.subtype.rawValue):
            return .userAlbum
        default:
            return nil
        }
    }

    private func makeAlbum(_ collection: LibraryCollection, kind: MediaAlbum.Kind) -> MediaAlbum? {
        // 列表构造期间相册被删：summary 为 nil，跳过这一项而不是报 0。
        guard let summary = library.summary(ofCollection: collection.id) else { return nil }
        return MediaAlbum(
            id: collection.id,
            title: albumTitleOrNil(collection.title),
            kind: kind,
            count: summary.count,
            imageCount: summary.imageCount,
            videoCount: summary.videoCount,
            coverAssetId: summary.newestAssetId
        )
    }
}

/// 名字为空或全是空白时返回 nil，交给 UI 本地化（对位 Android `bucketNameOrNull`）。
public func albumTitleOrNil(_ title: String?) -> String? {
    guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return title
}
