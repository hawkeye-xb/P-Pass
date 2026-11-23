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
        XCTAssertEqual(albums[0].imageCount, 0)
        XCTAssertEqual(albums[0].videoCount, 0)
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

    // MARK: #1949 大批量相册：一次批量统计、0 次逐 id 回退

    /// 80 个可选相册规模下，`listAlbums()` 只调 1 次批量 `collectionSummaries(matching:)`，
    /// 不回退逐 id `summary(ofCollection:)`；不可选集合被提前过滤、连统计都不查。
    /// 空相册、单元素相册、多元素相册、隐藏项过滤与最新 `creationDate` 封面的口径保持不变。
    func testEightyAlbumsUseSingleBatchCollectionSummariesWithoutPerIdSummaryLookups() {
        /// 记录批量调用次数、逐 id 回退次数与被统计的集合，统计委派给内存库。
        final class BatchSpy: PhotoLibraryReading {
            let base: FakePhotoLibrary
            var batchCalls = 0
            var perIdCalls = 0
            var excludedIds: [String] = []
            var summarizedIds: [String] = []
            init(_ base: FakePhotoLibrary) { self.base = base }

            func collections() -> [LibraryCollection] { base.collections() }

            func summary(ofCollection id: String) -> CollectionSummary? {
                perIdCalls += 1
                return base.summary(ofCollection: id)
            }

            func assetIdentifiers(inCollection id: String) -> [String]? { base.assetIdentifiers(inCollection: id) }

            func assetIdentifiers(inCollection id: String, among assetIds: [String]) -> [String]? {
                base.assetIdentifiers(inCollection: id, among: assetIds)
            }

            func userAlbumIdentifiers(containing assetIds: [String]) -> [String: [String]] {
                base.userAlbumIdentifiers(containing: assetIds)
            }

            func collectionSummaries(
                matching isIncluded: (LibraryCollection) -> Bool
            ) -> [(collection: LibraryCollection, summary: CollectionSummary)] {
                batchCalls += 1
                let all = base.collections()
                excludedIds = all.filter { !isIncluded($0) }.map(\.id)
                return all.compactMap { collection in
                    guard isIncluded(collection),
                          let summary = base.summary(ofCollection: collection.id) else { return nil }
                    summarizedIds.append(collection.id)
                    return (collection, summary)
                }
            }
        }

        let lib = FakePhotoLibrary()
        lib.add(.init(id: "lib-new", created: date(900)))
        lib.add(.init(id: "lib-old", created: date(100)))
        lib.add(.init(id: "hidden-new", created: date(9_999), hidden: true))
        lib.add(.init(id: "fav-asset", created: date(500)))
        lib.add(.init(id: "u08-solo", created: date(42)))
        lib.add(.init(id: "u09-a", created: date(100)))
        lib.add(.init(id: "u09-b", created: date(300)))
        for i in 1...70 {
            let id = String(format: "u%02d", i)
            switch i {
            case 7:
                lib.addCollection(id, title: "Album 7", assets: [])
            case 8:
                lib.addCollection(id, title: "Album 8", assets: ["u08-solo"])
            case 9:
                lib.addCollection(id, title: "Album 9", assets: ["u09-a", "hidden-new", "u09-b"])
            default:
                lib.add(.init(id: "\(id)-asset", created: date(Double(i))))
                lib.addCollection(id, title: "Album \(i)", assets: ["\(id)-asset"])
            }
        }
        lib.addCollection("recents", title: "Recents", type: .smartAlbum, subtype: .smartAlbumUserLibrary,
                          assets: ["lib-new", "lib-old"])
        lib.addCollection("fav", title: "Favorites", type: .smartAlbum, subtype: .smartAlbumFavorites, assets: ["fav-asset"])
        for (id, subtype) in [
            ("videos", PHAssetCollectionSubtype.smartAlbumVideos),
            ("selfies", .smartAlbumSelfPortraits),
            ("live", .smartAlbumLivePhotos),
            ("depth", .smartAlbumDepthEffect),
            ("panoramas", .smartAlbumPanoramas),
            ("timelapses", .smartAlbumTimelapses),
            ("slomo", .smartAlbumSlomoVideos),
            ("cinematic", .smartAlbumCinematic),
        ] {
            lib.addCollection(id, title: id, type: .smartAlbum, subtype: subtype)
        }
        // 不可选：隐藏、最近添加、共享相簿、照片流、白名单外智能相册。
        lib.addCollection("all-hidden", title: "Hidden", type: .smartAlbum, subtype: .smartAlbumAllHidden, assets: ["lib-new"])
        lib.addCollection("recent-added", title: "Recently Added", type: .smartAlbum, subtype: .smartAlbumRecentlyAdded, assets: ["lib-new"])
        lib.addCollection("cloud-shared", title: "家人共享", type: .album, subtype: .albumCloudShared, assets: ["lib-new"])
        lib.addCollection("stream", title: "My Photo Stream", type: .album, subtype: .albumMyPhotoStream, assets: ["lib-old"])
        lib.addCollection("generic", title: "Generic", type: .smartAlbum, subtype: .smartAlbumGeneric, assets: ["lib-new"])

        let spy = BatchSpy(lib)
        let albums = AlbumCatalog(library: spy).listAlbums()
        let byId = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })

        XCTAssertEqual(spy.batchCalls, 1, "80 个相册只允许 1 次批量统计")
        XCTAssertEqual(spy.perIdCalls, 0, "listAlbums 不得回退到逐 id summary(ofCollection:)")
        XCTAssertEqual(spy.summarizedIds.count, 80, "1 个最近项目 + 70 个用户相册 + 9 个可选智能相册")
        XCTAssertEqual(
            Set(spy.excludedIds),
            ["all-hidden", "recent-added", "cloud-shared", "stream", "generic"],
            "不可选集合必须被 isIncluded 提前过滤"
        )
        XCTAssertTrue(spy.excludedIds.filter(spy.summarizedIds.contains).isEmpty, "不可选集合不得进入统计")
        XCTAssertEqual(Set(lib.queried), Set(spy.summarizedIds), "内存库只被问过可选集合")

        let expectedIds = ["recents"] + (1...70).map { String(format: "u%02d", $0) } + ["fav"]
        XCTAssertEqual(albums.map(\.id), expectedIds,
                       "最近项目在前 → 用户相册原序（含空）→ 非空可选智能相册按白名单序")

        XCTAssertEqual(byId["recents"]?.count, 2)
        XCTAssertEqual(byId["recents"]?.coverAssetId, "lib-new")

        XCTAssertEqual(byId["u07"]?.count, 0)
        XCTAssertNil(byId["u07"]?.coverAssetId, "空相册没有封面")

        XCTAssertEqual(byId["u08"]?.count, 1)
        XCTAssertEqual(byId["u08"]?.coverAssetId, "u08-solo", "单元素相册免排序，唯一一张就是封面")

        XCTAssertEqual(byId["u09"]?.count, 2)
        XCTAssertEqual(byId["u09"]?.imageCount, 2)
        XCTAssertEqual(byId["u09"]?.videoCount, 0)
        XCTAssertEqual(byId["u09"]?.coverAssetId, "u09-b", "隐藏项再新也不计数、不当封面；封面按 creationDate 最新")
    }
}
