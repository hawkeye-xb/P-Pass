import XCTest
import Photos
@testable import PPassMedia

/// ``AlbumMembership``：按张反查（`of`）与全表（`all`）对每张照片给出完全相同的范围键（不漏判、不多判）。
/// 真库上造不出的形状（隐藏项、音频、共享相簿、照片流、同步相册）在这里钉住；真 PhotoKit 的核对在 AlbumMembershipIT。
final class AlbumMembershipTests: XCTestCase {
    private func library() -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        for id in ["p1", "p2", "p3", "solo"] { lib.add(.init(id: id)) }
        lib.add(.init(id: "v", mediaType: .video))
        lib.add(.init(id: "hidden", hidden: true))
        lib.add(.init(id: "audio", mediaType: .audio))
        lib.add(.init(id: "shared-only"))
        lib.addCollection("recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary,
                          assets: ["p1", "p2", "p3", "solo", "v", "hidden", "audio", "shared-only"])
        lib.addCollection("fav", title: "Favorites", type: .smartAlbum, subtype: .smartAlbumFavorites, assets: ["p2", "hidden"])
        lib.addCollection("videos", title: "Videos", type: .smartAlbum, subtype: .smartAlbumVideos, assets: ["v"])
        lib.addCollection("shots-empty", title: "Screenshots", type: .smartAlbum, subtype: .smartAlbumScreenshots)
        lib.addCollection("recent-added", title: "Recently Added", type: .smartAlbum, subtype: .smartAlbumRecentlyAdded, assets: ["p1"])
        lib.addCollection("b-trip", title: "Trip", assets: ["p1", "p2", "hidden", "audio"])
        lib.addCollection("a-family", title: "Family", assets: ["p2", "v"])
        lib.addCollection("synced", title: "From Mac", subtype: .albumSyncedAlbum, assets: ["p3"])
        lib.addCollection("shared", title: "家人共享", type: .album, subtype: .albumCloudShared, assets: ["p1", "shared-only"])
        lib.addCollection("stream", title: "My Photo Stream", type: .album, subtype: .albumMyPhotoStream, assets: ["p3"])
        return lib
    }

    private let everyone = ["p1", "p2", "p3", "solo", "v", "hidden", "audio", "shared-only", "gone"]

    func testPerAssetKeysEqualFullTableKeysOneByOneAndInBatch() {
        let membership = AlbumMembership(library: library())
        let all = membership.all()
        let batch = membership.of(everyone)
        for id in everyone {
            let expected = AlbumMembership.key(all[id])
            XCTAssertEqual(AlbumMembership.key(membership.of([id])[id]), expected, "单张 \(id)")
            XCTAssertEqual(AlbumMembership.key(batch[id]), expected, "批量 \(id)")
        }
        XCTAssertEqual(Set(batch.keys), Set(all.keys))
    }

    func testKeysAreSortedJoinedSelectableAlbumsOnly() {
        let of = AlbumMembership(library: library()).of(everyone)
        XCTAssertEqual(AlbumMembership.key(of["p2"]), "a-family\nb-trip\nfav\nrecents")
        XCTAssertEqual(AlbumMembership.key(of["p1"]), "b-trip\nrecents", "共享相簿、最近添加不算")
        XCTAssertEqual(AlbumMembership.key(of["p3"]), "recents\nsynced", "同步相册算（走精确查询），照片流不算")
        XCTAssertEqual(AlbumMembership.key(of["v"]), "a-family\nrecents\nvideos")
        XCTAssertEqual(AlbumMembership.key(of["solo"]), "recents", "只在最近项目里的照片")
        XCTAssertEqual(AlbumMembership.key(of["shared-only"]), "recents")
        XCTAssertEqual(AlbumMembership.key(of["hidden"]), "", "隐藏项不属于任何可选相册")
        XCTAssertEqual(AlbumMembership.key(of["audio"]), "", "音频不算")
        XCTAssertEqual(AlbumMembership.key(of["gone"]), "", "图库里已没有的照片")
    }

    /// 按张反查不拉统计、不列相册全部内容；普通用户相册走一次反查，其余可选集合逐个精确查。
    func testPerAssetPathDoesNotSummarizeOrListWholeAlbums() {
        final class Spy: PhotoLibraryReading {
            let base: FakePhotoLibrary
            var summaries = 0, wholeLists = 0, filtered: [String] = [], containing = 0
            init(_ base: FakePhotoLibrary) { self.base = base }
            func collections() -> [LibraryCollection] { base.collections() }
            func summary(ofCollection id: String) -> CollectionSummary? { summaries += 1; return base.summary(ofCollection: id) }
            func assetIdentifiers(inCollection id: String) -> [String]? { wholeLists += 1; return base.assetIdentifiers(inCollection: id) }
            func assetIdentifiers(inCollection id: String, among assetIds: [String]) -> [String]? {
                filtered.append(id); return base.assetIdentifiers(inCollection: id, among: assetIds)
            }
            func userAlbumIdentifiers(containing assetIds: [String]) -> [String: [String]] {
                containing += 1; return base.userAlbumIdentifiers(containing: assetIds)
            }
        }
        let spy = Spy(library())
        _ = AlbumMembership(library: spy).of(["p1", "p2"])
        XCTAssertEqual(spy.summaries, 0)
        XCTAssertEqual(spy.wholeLists, 0)
        XCTAssertEqual(spy.containing, 1)
        XCTAssertEqual(Set(spy.filtered), ["recents", "fav", "videos", "shots-empty", "synced"], "智能相册与同步相册不信反查")
        _ = AlbumMembership(library: spy).of([])
        XCTAssertEqual(spy.containing, 1, "空输入不查库")
    }

    func testSelectableCollectionsAreTheListedAlbumsPlusEmptySmartAlbums() {
        let lib = library()
        let selectable = Set(AlbumCatalog(library: lib).selectableCollections().map(\.id))
        let listed = Set(AlbumCatalog(library: lib).listAlbums().map(\.id))
        XCTAssertEqual(selectable, listed.union(["shots-empty"]), "差别只在「智能相册须非空」这一条")
    }
}
