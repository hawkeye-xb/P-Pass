import XCTest
import Photos
@testable import PPassMedia

/// IOS-08（#314）相册枚举的取舍与口径。真 PhotoKit 上的同一组形状见 IntegrationHost/Tests/AlbumEnumerationIT.swift。
final class AlbumCatalogTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: 卡面验收 5：空相册、无名相册、仅视频相册三种形状

    func testEmptyAlbumIsListedWithZeroCountAndNoCover() {
        let lib = FakePhotoLibrary()
        lib.addCollection("empty", title: "空的")

        let albums = AlbumCatalog(library: lib).listAlbums()

        XCTAssertEqual(albums.map(\.id), ["empty"])
        XCTAssertEqual(albums[0].count, 0)
        XCTAssertNil(albums[0].coverAssetId, "空相册没有封面，UI 退化为空白封面")
        XCTAssertEqual(albums[0].kind, .userAlbum)
    }

    func testNamelessAlbumsKeepNilTitleForUiToLocalize() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "p"))
        lib.addCollection("nil", title: nil, assets: ["p"])
        lib.addCollection("blank", title: "", assets: ["p"])
        lib.addCollection("spaces", title: "  \n", assets: ["p"])
        lib.addCollection("named", title: " 旅行 ", assets: ["p"])

        let titles = Dictionary(uniqueKeysWithValues: AlbumCatalog(library: lib).listAlbums().map { ($0.id, $0.title) })

        XCTAssertEqual(titles["nil"], .some(nil))
        XCTAssertEqual(titles["blank"], .some(nil))
        XCTAssertEqual(titles["spaces"], .some(nil))
        XCTAssertEqual(titles["named"], " 旅行 ", "有内容的名字原样保留，不替用户修剪")
    }

    func testVideoOnlyAlbumCountsVideosAndUsesNewestVideoAsCover() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "v-old", mediaType: .video, created: date(100)))
        lib.add(.init(id: "v-new", mediaType: .video, created: date(200)))
        lib.addCollection("videos", title: "只有视频", assets: ["v-old", "v-new"])

        let album = AlbumCatalog(library: lib).listAlbums()[0]

        XCTAssertEqual(album.count, 2)
        XCTAssertEqual(album.imageCount, 0)
        XCTAssertEqual(album.videoCount, 2)
        XCTAssertEqual(album.coverAssetId, "v-new")
    }

    // MARK: 卡面验收 3：封面 = 相册内最新一项

    func testCoverIsNewestByCreationDateNotAlbumOrder() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "newest", created: date(300)))
        lib.add(.init(id: "middle", created: date(200)))
        lib.add(.init(id: "oldest", created: date(100)))
        lib.addCollection("a", title: "A", assets: ["newest", "oldest", "middle"])

        XCTAssertEqual(AlbumCatalog(library: lib).listAlbums()[0].coverAssetId, "newest")
    }

    // MARK: 卡面验收 4：「已隐藏」「最近删除」不得出现在可选范围里

    func testHiddenRecentlyDeletedAndOtherSystemCollectionsAreNeverSelectable() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "p"))
        lib.add(.init(id: "h", hidden: true))
        lib.addCollection("hidden", title: "Hidden", type: .smartAlbum, subtype: .smartAlbumAllHidden, assets: ["p", "h"])
        // 「最近删除」不是公开子类型；若某个系统版本把它枚举出来，原始值是 1000000201。
        lib.addCollection("deleted", title: "Recently Deleted", type: .smartAlbum,
                          subtype: PHAssetCollectionSubtype(rawValue: 1_000_000_201)!, assets: ["p"])
        lib.addCollection("recent-added", title: "Recently Added", type: .smartAlbum, subtype: .smartAlbumRecentlyAdded, assets: ["p"])
        lib.addCollection("generic", title: "Generic", type: .smartAlbum, subtype: .smartAlbumGeneric, assets: ["p"])
        lib.addCollection("unable", title: "Unable to Upload", type: .smartAlbum, subtype: .smartAlbumUnableToUpload, assets: ["p"])
        lib.addCollection("shared", title: "家人共享", type: .album, subtype: .albumCloudShared, assets: ["p"])
        lib.addCollection("stream", title: "My Photo Stream", type: .album, subtype: .albumMyPhotoStream, assets: ["p"])
        lib.addCollection("mine", title: "我的相册", assets: ["p"])

        let albums = AlbumCatalog(library: lib).listAlbums()

        XCTAssertEqual(albums.map(\.id), ["mine"])
        for album in albums {
            if case .smartAlbum(let subtype) = album.kind {
                XCTAssertNotEqual(subtype, .smartAlbumAllHidden)
                XCTAssertNotEqual(subtype.rawValue, 1_000_000_201)
            }
        }
    }

    func testHiddenAssetsDoNotCountInTheirUserAlbum() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "shown"))
        lib.add(.init(id: "hidden", created: date(999), hidden: true))
        lib.addCollection("a", title: "A", assets: ["shown", "hidden"])

        let album = AlbumCatalog(library: lib).listAlbums()[0]

        XCTAssertEqual(album.count, 1)
        XCTAssertEqual(album.coverAssetId, "shown", "隐藏项再新也不能当封面")
        XCTAssertEqual(AlbumScope(library: lib).assetIdentifiers(inAlbums: ["a"]), ["shown"])
    }

    // MARK: 智能相册取舍与顺序

    func testLibraryFirstThenUserAlbumsInSystemOrderThenNonEmptySmartAlbums() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "p"))
        lib.addCollection("fav-empty", title: "Favorites", type: .smartAlbum, subtype: .smartAlbumFavorites)
        lib.addCollection("shots", title: "Screenshots", type: .smartAlbum, subtype: .smartAlbumScreenshots, assets: ["p"])
        lib.addCollection("videos", title: "Videos", type: .smartAlbum, subtype: .smartAlbumVideos, assets: ["p"])
        lib.addCollection("recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary, assets: ["p"])
        lib.addCollection("z-album", title: "Zoo", assets: ["p"])
        lib.addCollection("a-album", title: "Apple", assets: [])
        lib.addCollection("synced", title: "From Mac", subtype: .albumSyncedAlbum, assets: ["p"])

        let albums = AlbumCatalog(library: lib).listAlbums()

        XCTAssertEqual(albums.map(\.id), ["recents", "z-album", "a-album", "synced", "videos", "shots"],
                       "最近项目在前；用户相册保持系统顺序（不按字母重排）、空的也列；智能相册按白名单顺序且空的不列")
        XCTAssertEqual(albums[0].kind, .library)
        XCTAssertEqual(albums.last?.kind, .smartAlbum(.smartAlbumScreenshots))
    }

    func testEmptyLibraryAlbumIsStillListed() {
        let lib = FakePhotoLibrary()
        lib.addCollection("recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary)

        XCTAssertEqual(AlbumCatalog(library: lib).listAlbums().map(\.id), ["recents"],
                       "图库为空也要能选「最近项目」——之后拍的照片都进它")
    }

    func testAlbumVanishingDuringListingIsSkippedNotReportedAsZero() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "p"))
        lib.addCollection("gone", title: "Gone", assets: ["p"])
        lib.addCollection("kept", title: "Kept", assets: ["p"])
        lib.vanished = ["gone"]

        XCTAssertEqual(AlbumCatalog(library: lib).listAlbums().map(\.id), ["kept"])
    }

    // MARK: 范围计数口径（README 差异 ①）

    func testScopeCountIsUnionNotSumOfAlbumCounts() {
        let lib = FakePhotoLibrary()
        for id in ["a", "b", "c", "d"] { lib.add(.init(id: id)) }
        lib.addCollection("recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary, assets: ["a", "b", "c", "d"])
        lib.addCollection("trip", title: "Trip", assets: ["a", "b"])
        lib.addCollection("family", title: "Family", assets: ["b", "c"])

        let albums = Dictionary(uniqueKeysWithValues: AlbumCatalog(library: lib).listAlbums().map { ($0.id, $0) })
        let scope = AlbumScope(library: lib)

        XCTAssertEqual(albums["trip"]!.count + albums["family"]!.count, 4)
        XCTAssertEqual(scope.count(inAlbums: ["trip", "family"]), 3, "b 同时在两个相册里，只算一次")
        XCTAssertEqual(scope.assetIdentifiers(inAlbums: ["trip", "family"]), ["a", "b", "c"])
        XCTAssertEqual(scope.count(inAlbums: ["recents", "trip", "family"]), 4, "选了「最近项目」再加别的相册不会超过图库总数")
    }

    func testEmptyScopeQueriesNothing() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "a"))
        lib.addCollection("trip", title: "Trip", assets: ["a"])

        XCTAssertEqual(AlbumScope(library: lib).count(inAlbums: []), 0)
        XCTAssertTrue(lib.queried.isEmpty, "空范围 = 一个都不备，不发查询")
    }

    func testDeletedAlbumInScopeContributesNothing() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "a"))
        lib.addCollection("trip", title: "Trip", assets: ["a"])

        XCTAssertEqual(AlbumScope(library: lib).assetIdentifiers(inAlbums: ["trip", "deleted-album"]), ["a"])
    }

    func testAudioIsNeverCounted() {
        let lib = FakePhotoLibrary()
        lib.add(.init(id: "song", mediaType: .audio))
        lib.add(.init(id: "p"))
        lib.addCollection("mixed", title: "Mixed", assets: ["song", "p"])

        XCTAssertEqual(AlbumCatalog(library: lib).listAlbums()[0].count, 1)
        XCTAssertEqual(AlbumScope(library: lib).assetIdentifiers(inAlbums: ["mixed"]), ["p"])
    }
}
