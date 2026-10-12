import XCTest
import Photos
import PPassMedia

/// IOS-09（#335）验收 3：在真库上**真的**造出 3105，并证明全量重扫按内容收敛、不重传。
///
/// 造法（scripts/test.sh 编排，两轮之间 erase 模拟器）：
/// - 第一轮 `testPhase1_BackUpLibraryAndKeepToken`：先往图库里连续写 ``surplusChanges`` 次变更，把历史推长；
///   再把图库里每一项的原始字节存进一个目录，当作「桌面上已有的内容」；最后存下当时的 token，当作「已提交的 G」。
/// - erase 模拟器，再用同一批素材 addmedia。图库换了一个，内容相同，但 localIdentifier 全变了，历史也短得多。
/// - 第二轮 `testPhase2_ExpiredTokenRescanConvergesByContent`：拿旧 token 读历史，系统回 3105（实测）。
///
/// 为什么要先把历史推长（实测得出）：token 看起来只记录历史里的位置，不绑定是哪个图库。旧 token 的位置如果还落在新图库的
/// 历史范围内，系统**不报错**，会照常返回「从那个位置之后」的变更，而那其实是另一个图库的历史。只有位置超出新图库的历史时，
/// 才会回 3105。这件事登记在 README 的风险里：G 错位时不报错的情况，要靠对账扫描兜住。
///   按兜底走全量重扫，逐项比对内容：只有第二轮新拍的那一张需要传。按 id 判会把整个图库重传一遍，按计数判也判不对。
///
/// 内容比对直接比原始字节（夹具都很小）。BLAKE3 从 XCFramework 来（#313），这里不实现；
/// 字节相同就意味着任何内容哈希都相同，判据不变。
final class TokenExpiryIT: XCTestCase {
    /// 第一轮多写的变更数，要明显多于第二轮全部集成测试会产生的变更数（目前十来次）。
    static let surplusChanges = 40

    private func env(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else {
            throw XCTSkip("\(key) not set——由 scripts/test.sh 的两轮编排设置")
        }
        return URL(fileURLWithPath: path)
    }

    func testPhase1_BackUpLibraryAndKeepToken() throws {
        let tokenFile = try env("PPASS_MEDIA_TOKEN_DUMP")
        let desktop = try env("PPASS_MEDIA_DESKTOP_DIR")
        try IT.requireFullAccess()
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        for i in 0..<Self.surplusChanges { _ = try IT.createPhoto(label: "history-\(IT.nonce)-\(i)") }

        let all = PHAsset.fetchAssets(with: nil)
        var n = 0
        for asset in all.objects(at: IndexSet(integersIn: 0..<all.count)) {
            try IT.originalBytes(of: asset).write(to: desktop.appendingPathComponent("\(n).bin"))
            n += 1
        }
        try PhotoKitChangeHistory().currentToken().archived.write(to: tokenFile)
        print("IT-EXPIRY phase1 backed-up=\(n) token-bytes=\(try Data(contentsOf: tokenFile).count)")
    }

    func testPhase2_ExpiredTokenRescanConvergesByContent() throws {
        let tokenFile = try env("PPASS_MEDIA_FOREIGN_TOKEN")
        let desktop = try env("PPASS_MEDIA_DESKTOP_DIR")
        try IT.requireFullAccess()
        let staleG = ChangeToken(archived: try Data(contentsOf: tokenFile))
        let onDesktop = Set(try FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) })

        // 系统 API 原样：3105
        let decoded = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: staleG.archived))
        XCTAssertThrowsError(try PHPhotoLibrary.shared().fetchPersistentChanges(since: decoded)) { error in
            let ns = error as NSError
            print("IT-EXPIRY raw fetchPersistentChanges error domain=\(ns.domain) code=\(ns.code)")
            XCTAssertEqual(ns.domain, PHPhotosErrorDomain)
            XCTAssertEqual(ns.code, PHPhotosError.persistentChangeTokenExpired.rawValue)
        }

        let newId = try IT.createPhoto(label: "after-expiry-\(IT.nonce)")

        let discovery = ChangeDiscovery(history: PhotoKitChangeHistory())
        guard case .rescan(let reason, let restartAt) = try discovery.discover(since: staleG) else {
            return XCTFail("expected rescan")
        }
        XCTAssertEqual(reason, .tokenExpired)

        // 全量重扫：范围 = 最近项目
        let albums = AlbumCatalog(library: PhotoKitLibrary()).listAlbums()
        let recents = try XCTUnwrap(albums.first { $0.kind == .library })
        let inScope = AlbumScope(library: PhotoKitLibrary()).assetIdentifiers(inAlbums: [recents.id])
        var transferred: [String] = []
        var deduped = 0
        for id in inScope.sorted() {
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
            if onDesktop.contains(try IT.originalBytes(of: asset)) { deduped += 1 } else { transferred.append(id) }
        }
        print("IT-EXPIRY phase2 in-scope=\(inScope.count) desktop-has=\(onDesktop.count) deduped=\(deduped) transferred=\(transferred.map(IT.filename))")
        // 第二轮里别的集成测试也会新建照片（文件名都是 ppit- 开头，第一轮的 ppit-history-* 在新图库里不存在）。
        // 判据：系统样例照片和 addmedia 灌的素材（第一轮就有的内容）全部判重；要传的只有第二轮新建的照片，且包含本测试新建的那张。
        let baseline = inScope.filter { !IT.filename(of: $0).hasPrefix("ppit-") }
        XCTAssertEqual(deduped, baseline.count, "第一轮就有的内容全部按内容判重，不重传")
        XCTAssertEqual(Set(transferred), inScope.subtracting(baseline))
        XCTAssertTrue(transferred.contains(newId))
        XCTAssertTrue(transferred.allSatisfy { !IT.filename(of: $0).hasPrefix("ppit-history-") })
        XCTAssertEqual(baseline.count, 9, "6 张系统样例 + a1.jpg / h1.heic / v1.mp4")

        // 重扫后 G = restartAt，增量能继续用
        guard case .changes(let window) = try discovery.discover(since: restartAt) else { return XCTFail("restartAt 应可用于增量") }
        XCTAssertEqual(window.newAssetIds, [], "restartAt 在新照片之后取，新照片已由重扫覆盖")
    }
}
