import XCTest
import Photos
import PPassMedia

/// #958：取件按张反查所属相册（`AlbumMembership.of`）在真 PhotoKit 上与全表（`all`，旧算法）逐张给出完全相同的范围键。
///
/// 场景：同一张照片在多个用户相册里、文件夹里的相册、个人收藏（智能相册）、视频（智能相册）、只在「最近项目」里的照片；
/// 外加 40 个用户相册和 60 张照片，让计时有点规模（模拟器数字，不代表真机绝对值）。
final class AlbumMembershipIT: XCTestCase {
    func testPerAssetKeysMatchFullTableAcrossWholeLibrary() throws {
        try IT.requireFullAccess()
        _ = try IT.fixtureDir()
        let jpeg = try IT.asset(originalFilename: "a1.jpg")
        let heic = try IT.asset(originalFilename: "h1.heic")
        let video = try IT.asset(originalFilename: "v1.mp4")
        let n = IT.nonce

        let bulk = try createPhotos(count: 60, label: "mbr-\(n)")
        // fetchAssets(withLocalIdentifiers:) 不保证按传入顺序返回，按 bulk 的顺序重排，soloId 才真的不进任何用户相册。
        var byId: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: bulk, options: nil).enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }
        let bulkAssets = try bulk.map { try XCTUnwrap(byId[$0]) }
        let soloId = bulk[0] // 不进任何用户相册：只在「最近项目」里
        // 全部相册在一次变更里建完（加上建照片、设收藏共 3 次）：TokenExpiryIT 第二轮要求本轮集成测试的变更历史
        // 短于它第一轮预埋的 surplusChanges，一相册一次变更会把历史推长、让它造不出 3105。
        var specs: [(title: String, assets: [PHAsset], folder: String?)] = [
            ("MBR-\(n)-trip", [jpeg, heic] + bulkAssets[1..<20], nil),
            ("MBR-\(n)-family", [heic, video] + bulkAssets[10..<30], nil),
            ("MBR-\(n)-nested", [heic], "MBR-\(n)-folder"),
        ]
        for i in 0..<40 { specs.append(("MBR-\(n)-x\(i)", Array(bulkAssets[(1 + i)..<(1 + i + 15)]), nil)) }
        let albumIds = try createAlbums(specs)
        let (trip, family, nested) = (albumIds[0], albumIds[1], albumIds[2])
        try IT.perform { PHAssetChangeRequest(for: heic).isFavorite = true }

        let library = PhotoKitLibrary()
        let membership = AlbumMembership(library: library)
        let catalog = AlbumCatalog(library: library).selectableCollections()
        let favorites = try XCTUnwrap(catalog.first { $0.subtype == .smartAlbumFavorites }, "个人收藏可选").id
        let videos = try XCTUnwrap(catalog.first { $0.subtype == .smartAlbumVideos }, "视频可选").id
        let recents = try XCTUnwrap(catalog.first { $0.subtype == .smartAlbumUserLibrary }, "最近项目可选").id

        // 反查对智能相册一律返回空、对用户相册（含嵌套）有效——智能相册因此必须逐个带谓词查（打出来留证）。
        // 不对 smartAlbum=0 作断言：产品代码不依赖「智能相册反查为空」，哪天系统开始返回了也不影响正确性。
        for asset in [jpeg, heic, video] {
            let smart = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .smartAlbum, options: nil).count
            let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).count
            print("IT-MEMBERSHIP-CONTAINING \(IT.filename(of: asset.localIdentifier)) smartAlbum=\(smart) album=\(albums)")
        }

        // 旧算法全表 vs 新算法：整个图库逐张、再整批一次（取件按页批量调用）
        let all = membership.all()
        var everyone: [String] = []
        PHAsset.fetchAssets(with: nil).enumerateObjects { a, _, _ in everyone.append(a.localIdentifier) }
        XCTAssertGreaterThanOrEqual(everyone.count, 63)
        let batch = membership.of(everyone)
        var mismatches: [String] = []
        for id in everyone {
            let expected = AlbumMembership.key(all[id])
            let single = AlbumMembership.key(membership.of([id])[id])
            if single != expected || AlbumMembership.key(batch[id]) != expected { mismatches.append(id) }
        }
        XCTAssertEqual(mismatches, [], "新旧范围键必须逐字相等：不漏判、也不多判")
        XCTAssertEqual(Set(batch.keys), Set(all.keys))
        print("IT-MEMBERSHIP-EQUAL assets=\(everyone.count) selectable=\(catalog.count) mismatches=\(mismatches.count)")

        // 场景逐个钉住（键里确实带上了智能相册，不是两边都漏）
        // 素材三张也会被同进程里别的集成测试放进它们自己的相册，所以对它们只核「本测试的这些相册都在」；
        // 本测试新建的照片只有本测试碰过，可以核精确值。
        let heicAlbums = Set(try XCTUnwrap(batch[heic.localIdentifier]))
        XCTAssertTrue(heicAlbums.isSuperset(of: [trip, family, nested, favorites, recents]), "多个用户相册 + 嵌套 + 收藏 + 最近项目")
        XCTAssertTrue(Set(try XCTUnwrap(batch[video.localIdentifier])).isSuperset(of: [family, videos, recents]), "视频智能相册")
        XCTAssertFalse(Set(try XCTUnwrap(batch[jpeg.localIdentifier])).contains(favorites))
        XCTAssertEqual(batch[soloId], [recents], "只在最近项目里")

        // 计时：旧 = 每次取件都拼一遍全表；新 = 单张反查 / 一页 20 张反查
        let rounds = 20
        let oldMs = measureMs(rounds) { _ = membership.all() }
        let singleMs = measureMs(rounds) { _ = membership.of([heic.localIdentifier]) }
        let page = Array(bulk.prefix(20))
        let pageMs = measureMs(rounds) { _ = membership.of(page) }
        // 对照：全部可选集合都逐个带谓词查（纯 Immich 做法、不用反查）的单张耗时——普通相册混用反查的依据。
        let preciseMs = measureMs(rounds) {
            for c in AlbumCatalog(library: library).selectableCollections() {
                _ = library.assetIdentifiers(inCollection: c.id, among: [heic.localIdentifier])
            }
        }
        print(String(format: "IT-MEMBERSHIP-TIMING library=%d selectable=%d old_all=%.2fms new_single=%.2fms new_page20=%.2fms all_precise_single=%.2fms (simulator, avg of %d)",
                     everyone.count, catalog.count, oldMs, singleMs, pageMs, preciseMs, rounds))
    }

    private func measureMs(_ rounds: Int, _ body: () -> Void) -> Double {
        body() // 预热
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<rounds { body() }
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(rounds)
    }

    private func createAlbums(_ specs: [(title: String, assets: [PHAsset], folder: String?)]) throws -> [String] {
        var ids: [String] = []
        try IT.perform {
            for spec in specs {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: spec.title)
                request.addAssets(spec.assets as NSArray)
                let placeholder = request.placeholderForCreatedAssetCollection
                ids.append(placeholder.localIdentifier)
                if let folder = spec.folder {
                    PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folder).addChildCollections([placeholder] as NSArray)
                }
            }
        }
        XCTAssertEqual(ids.count, specs.count)
        return ids
    }

    private func createPhotos(count: Int, label: String) throws -> [String] {
        let urls = try (0..<count).map { try IT.writeUniqueJPEG(label: "\(label)-\($0)") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        var ids: [String] = []
        try IT.perform {
            for url in urls {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent // ppit- 前缀：TokenExpiryIT 按它区分本轮新建的照片
                request.addResource(with: .photo, fileURL: url, options: options)
                if let id = request.placeholderForCreatedAsset?.localIdentifier { ids.append(id) }
            }
        }
        XCTAssertEqual(ids.count, count)
        return ids
    }
}
