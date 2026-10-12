import XCTest
import Photos
import UIKit

/// 集成测试的公共夹具。全部跑在模拟器的真 PhotoKit 上，宿主 App 已由 scripts/test.sh 设成完整授权。
enum IT {
    /// scripts/test.sh 用 `simctl addmedia` 灌进去的素材所在目录（经 TEST_RUNNER_ 前缀注入）。
    static func fixtureDir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PPASS_MEDIA_FIXTURE_DIR"], !path.isEmpty else {
            throw XCTSkip("PPASS_MEDIA_FIXTURE_DIR 未设置——请用 scripts/test.sh 跑集成测试")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 本轮夹具名前缀：同一台模拟器重复跑时互不干扰（scripts/test.sh 每轮会 erase，这里是双保险）。
    static let nonce = String(UUID().uuidString.prefix(8))

    static func requireFullAccess(file: StaticString = #filePath, line: UInt = #line) throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            XCTFail("宿主需要完整相册授权，当前 status=\(status.rawValue)；请用 scripts/test.sh 跑", file: file, line: line)
            throw XCTSkip("no full photo access")
        }
    }

    /// 在图库里按原始文件名找 addmedia 灌进来的那一项。
    static func asset(originalFilename name: String) throws -> PHAsset {
        let all = PHAsset.fetchAssets(with: nil)
        var found: [PHAsset] = []
        all.enumerateObjects { asset, _, _ in
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename == name }) {
                found.append(asset)
            }
        }
        guard found.count == 1 else {
            throw NSError(domain: "IT", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected exactly one asset named \(name), found \(found.count)"])
        }
        return found[0]
    }

    static func perform(_ changes: @escaping () -> Void) throws {
        try PHPhotoLibrary.shared().performChangesAndWait(changes)
    }

    /// 建一个相册并放进给定资产，返回相册 localIdentifier。
    static func createAlbum(title: String, assets: [PHAsset], inFolder folderTitle: String? = nil) throws -> String {
        var albumId: String?
        try perform {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets(assets as NSArray)
            let placeholder = request.placeholderForCreatedAssetCollection
            albumId = placeholder.localIdentifier
            if let folderTitle {
                let folder = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderTitle)
                folder.addChildCollections([placeholder] as NSArray)
            }
        }
        return try XCTUnwrap(albumId)
    }

    /// 生成一张内容唯一的 JPEG 并写进图库，返回 localIdentifier。
    static func createPhoto(label: String = UUID().uuidString) throws -> String {
        let url = try writeUniqueJPEG(label: label)
        defer { try? FileManager.default.removeItem(at: url) }
        var id: String?
        try perform {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "ppit-\(label).jpg"
            request.addResource(with: .photo, fileURL: url, options: options)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        // 注：不提供「建一张隐藏照片」——创建请求里设 isHidden 时 performChangesAndWait 不报错、但资产根本没建出来；
        // 建好后再用 PHAssetChangeRequest 隐藏，系统会弹「允许 xx 隐藏这张照片？」确认框，单元测试会卡死（实测截图）。
        // 隐藏项口径因此由包内 fake 测试（E2）覆盖，真库上只核实「已隐藏」集合本身不可选。
        let created = try XCTUnwrap(id)
        return created
    }

    static func writeUniqueJPEG(label: String) throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { ctx in
            UIColor(hue: CGFloat(abs(label.hashValue % 360)) / 360, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            (label as NSString).draw(at: CGPoint(x: 2, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 6)])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ppit-\(label).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    static func filename(of assetId: String?) -> String {
        guard let assetId, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return "-" }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
    }

    /// 原图资源的完整字节（测试用的直接读法；产品路径见 IOS-11 的资源读取模块）。
    static func originalBytes(of asset: PHAsset) throws -> Data {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let resource = try XCTUnwrap(resources.first { $0.type == wanted } ?? resources.first)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        var data = Data()
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { data.append($0) }) {
            failure = $0
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
        return data
    }
}
