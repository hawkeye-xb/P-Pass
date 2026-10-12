import Foundation

/// 「范围内照片」= 所选相册里照片与视频的**并集**（按 `localIdentifier` 去重）。
///
/// 这是与 Android 口径最大的不同（README 差异 ①）：MediaStore 的 bucket 互斥，一张照片只在一个 bucket 里，
/// 范围计数 = 各 bucket 计数之和；PhotoKit 里一张照片可以同时在「最近项目」「个人收藏」和两个用户相册里，
/// 各相册 count 相加会重复计数。ARCH-01 的待办现算公式「范围内照片 − 跳过名单 − 已确认」里的
/// 「范围内照片」在 iOS 上就由这里给出，**分母永远是并集大小**，不是 `MediaAlbum.count` 之和。
public struct AlbumScope {
    private let library: PhotoLibraryReading

    public init(library: PhotoLibraryReading) {
        self.library = library
    }

    /// 所选相册的并集。范围空集 = 一个都不备（对位 FIX-T6：不发查询、直接空）。
    /// 已不存在的相册（用户删了）贡献空集，不报错——与 Android bucket 消失后自然查不到一致。
    public func assetIdentifiers(inAlbums albumIds: Set<String>) -> Set<String> {
        var union = Set<String>()
        for id in albumIds.sorted() {
            guard let ids = library.assetIdentifiers(inCollection: id) else { continue }
            union.formUnion(ids)
        }
        return union
    }

    /// 范围计数（精确、去重）。
    public func count(inAlbums albumIds: Set<String>) -> Int {
        assetIdentifiers(inAlbums: albumIds).count
    }
}
