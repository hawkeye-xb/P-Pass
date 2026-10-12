import XCTest
import Photos
import PPassMedia

/// IOS-08（#314）在模拟器真 PhotoKit 上的验收：灌进去的素材与建出来的相册，枚举结果逐条对上。
final class AlbumEnumerationIT: XCTestCase {
    func testAlbumsMatchWhatWasPutIntoTheLibrary() throws {
        try IT.requireFullAccess()
        _ = try IT.fixtureDir()
        let jpeg = try IT.asset(originalFilename: "a1.jpg")
        let heic = try IT.asset(originalFilename: "h1.heic")
        let video = try IT.asset(originalFilename: "v1.mp4")
        XCTAssertEqual(jpeg.mediaType, .image)
        XCTAssertEqual(heic.mediaType, .image)
        XCTAssertEqual(video.mediaType, .video)

        let n = IT.nonce
        let trip = try IT.createAlbum(title: "PPIT-\(n)-trip", assets: [jpeg, heic])
        let family = try IT.createAlbum(title: "PPIT-\(n)-family", assets: [heic, video])
        let empty = try IT.createAlbum(title: "PPIT-\(n)-empty", assets: [])
        let videoOnly = try IT.createAlbum(title: "PPIT-\(n)-videos", assets: [video])
        // 无名相册：PhotoKit 不让建（空串、空格、全角空格都回 3300 changeNotSupported，实测）。
        // 真库上造不出这个形状，空名 → nil 的映射由包内 fake 测试覆盖；这里钉住「造不出来」这条事实本身。
        for blank in ["", " ", "\u{3000}"] {
            XCTAssertThrowsError(try IT.createAlbum(title: blank, assets: [jpeg])) { error in
                XCTAssertEqual((error as NSError).domain, PHPhotosErrorDomain)
                XCTAssertEqual((error as NSError).code, PHPhotosError.changeNotSupported.rawValue)
            }
        }
        let nested = try IT.createAlbum(title: "PPIT-\(n)-nested", assets: [jpeg], inFolder: "PPIT-\(n)-folder")

        let library = PhotoKitLibrary()
        let albums = AlbumCatalog(library: library).listAlbums()
        let byId = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })

        print("IT-ALBUMS begin (\(albums.count))")
        for a in albums {
            print("IT-ALBUM | \(a.title ?? "<nil>") | \(a.kind) | count=\(a.count) img=\(a.imageCount) vid=\(a.videoCount) | cover=\(IT.filename(of: a.coverAssetId))")
        }
        print("IT-ALBUMS end")

        // 三种形状 + 重叠 + 嵌套
        let tripAlbum = try XCTUnwrap(byId[trip])
        XCTAssertEqual(tripAlbum.title, "PPIT-\(n)-trip")
        XCTAssertEqual(tripAlbum.kind, .userAlbum)
        XCTAssertEqual(tripAlbum.count, 2)
        XCTAssertEqual(tripAlbum.imageCount, 2)
        let newestOfTrip = [jpeg, heic].max { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }!
        XCTAssertEqual(tripAlbum.coverAssetId, newestOfTrip.localIdentifier, "封面 = creationDate 最新的一项")

        let familyAlbum = try XCTUnwrap(byId[family])
        XCTAssertEqual([familyAlbum.count, familyAlbum.imageCount, familyAlbum.videoCount], [2, 1, 1])

        let emptyAlbum = try XCTUnwrap(byId[empty], "空的用户相册也要列出")
        XCTAssertEqual(emptyAlbum.count, 0)
        XCTAssertNil(emptyAlbum.coverAssetId)

        let videoAlbum = try XCTUnwrap(byId[videoOnly])
        XCTAssertEqual([videoAlbum.count, videoAlbum.imageCount, videoAlbum.videoCount], [1, 0, 1])
        XCTAssertEqual(videoAlbum.coverAssetId, video.localIdentifier)

        let nestedAlbum = try XCTUnwrap(byId[nested], "文件夹里的相册也要能选到")
        XCTAssertEqual(nestedAlbum.count, 1)

        // 「最近项目」可选，且包含这些素材
        let recents = try XCTUnwrap(albums.first, "列表非空")
        XCTAssertEqual(recents.kind, .library, "最近项目排第一")
        let recentsIds = try XCTUnwrap(library.assetIdentifiers(inCollection: recents.id))
        XCTAssertTrue(Set(recentsIds).isSuperset(of: [jpeg.localIdentifier, heic.localIdentifier, video.localIdentifier]))
        // 独立口径核对：全库非隐藏的图片 + 视频（自己写 fetch，不借被测代码的 options）
        let images = PHAsset.fetchAssets(with: .image, options: nil).count
        let videos = PHAsset.fetchAssets(with: .video, options: nil).count
        XCTAssertEqual(recents.count, images + videos)
        print("IT-LIBRARY images=\(images) videos=\(videos) recents=\(recents.count)")

        // 卡面验收 4：隐藏 / 最近删除不在可选范围里（按子类型判，不按随语言变化的标题判）
        for album in albums {
            if case .smartAlbum(let subtype) = album.kind {
                XCTAssertTrue(AlbumCatalog.selectableSmartSubtypes.contains(subtype.rawValue))
                XCTAssertNotEqual(subtype, .smartAlbumAllHidden)
            }
        }
        let hiddenCollections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumAllHidden, options: nil)
        XCTAssertGreaterThan(hiddenCollections.count, 0, "系统确实有「已隐藏」这个集合，才谈得上把它挡掉")
        hiddenCollections.enumerateObjects { c, _, _ in XCTAssertNil(byId[c.localIdentifier]) }
        let smartRaw = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        var rawLines: [String] = []
        smartRaw.enumerateObjects { c, _, _ in
            rawLines.append("\(c.assetCollectionSubtype.rawValue):\(c.localizedTitle ?? "<nil>"):\(byId[c.localIdentifier] == nil ? "excluded" : "listed")")
        }
        print("IT-SMART-RAW \(rawLines.joined(separator: " | "))")
        XCTAssertFalse(rawLines.contains { $0.hasPrefix("1000000201:") && $0.hasSuffix(":listed") })

        // 范围口径：并集
        let scope = AlbumScope(library: library)
        XCTAssertEqual(scope.assetIdentifiers(inAlbums: [trip, family]),
                       [jpeg.localIdentifier, heic.localIdentifier, video.localIdentifier])
        XCTAssertEqual(tripAlbum.count + familyAlbum.count, 4)
        XCTAssertEqual(scope.count(inAlbums: [trip, family]), 3, "h1.heic 同时在两个相册里只算一次")
        XCTAssertEqual(scope.count(inAlbums: [recents.id, trip, family]), recents.count)
    }
}
