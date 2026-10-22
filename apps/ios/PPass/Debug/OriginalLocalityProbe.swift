#if DEBUG
import Foundation
import Photos
import PPassCore
import PPassMedia

/// 仅 DEBUG（#337 / #1016 真机取证）：原图此刻在不在本机，只用公开 API、不触发任何下载。
///
/// 做法：对将要备份的那份资源（``selectOriginalResource``）发一次 `requestData`，`isNetworkAccessAllowed = false`。
/// 收到第一块数据 = 在本机（随即取消，不读完）；系统报「需要网络」（PHPhotosError 3164）= 原图在 iCloud。
enum OriginalLocalityProbe {
    /// nil = 判断不了（照片不在、没有原图资源、其他错误）。
    static func isLocal(assetId: String) async -> Bool? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let index = selectOriginalResource(types: resources.map(\.type), mediaType: asset.mediaType) else { return nil }
        return await isLocal(resources[index])
    }

    static func isLocal(_ resource: PHAssetResource) async -> Bool? {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let state = ProbeState()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { _ in
                if state.markGotData(), let id = state.id { manager.cancelDataRequest(id) }
            }, completionHandler: { error in
                if state.gotData { continuation.resume(returning: true); return }
                guard let error = error as NSError? else { continuation.resume(returning: true); return } // 空文件
                if error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.networkAccessRequired.rawValue {
                    continuation.resume(returning: false)
                } else {
                    AppLog.log("probe: locality unknown (\(error.domain)#\(error.code))")
                    continuation.resume(returning: nil)
                }
            })
            state.id = id
            if state.gotData { manager.cancelDataRequest(id) }
        }
    }

    /// 启动时把 #337 的测试文件（原始文件名以 `ppass-test-` 开头，程序生成、经 Mac「照片」传进 iCloud）逐个记一行：
    /// 标签（A/B/C）、脱敏 id、媒体类型、资源类型、要备份的那份资源在不在本机、`fileSize`（#1016）读不读得到、修改时间。
    /// 只记测试文件，不碰用户自己的照片；只读，不下载。没有完全访问权限时什么都不做。
    static func logTestFilesAtLaunch() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        Task.detached(priority: .utility) {
            let all = PHAsset.fetchAssets(with: nil)
            var found: [(String, PHAsset, [PHAssetResource])] = []
            all.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                if let name = resources.first(where: { $0.type == .photo || $0.type == .video })?.originalFilename,
                   name.hasPrefix("ppass-test-") {
                    let label = String(name.dropFirst("ppass-test-".count).prefix { $0 != "." })
                    found.append((label, asset, resources))
                }
            }
            AppLog.log("probe: test files found=\(found.count) library=\(all.count)")
            for (label, asset, resources) in found.sorted(by: { $0.0 < $1.0 }) {
                let content = readOriginalContent(of: asset, resources: resources)
                let selected = content.resourceIndex.map { resources[$0] }
                let local = await selected.asyncMap { await isLocal($0) } ?? nil
                let modified = Int64((asset.modificationDate ?? .distantPast).timeIntervalSince1970)
                // 所属用户相册的子类型（不写相册名）：看测试相册有没有同步到手机。
                var albums: [String] = []
                PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                    .enumerateObjects { c, _, _ in albums.append(String(c.assetCollectionSubtype.rawValue)) }
                AppLog.log("probe: test=\(label) \(LogRedact.id(asset.localIdentifier)) mediaType=\(asset.mediaType.rawValue) "
                    + "resources=[\(resources.map { String($0.type.rawValue) }.joined(separator: ","))] "
                    + "selected=\(selected.map { String($0.type.rawValue) } ?? "-") local=\(local.map { $0 ? "yes" : "no" } ?? "unknown") "
                    + "fileSize=\(content.size.map(String.init) ?? "unreadable") version=\(content.version) modified=\(modified) "
                    + "userAlbums=[\(albums.joined(separator: ","))]")
            }
        }
    }
}

private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHAssetResourceDataRequestID?
    private var _gotData = false

    var id: PHAssetResourceDataRequestID? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); _id = newValue; lock.unlock() }
    }
    var gotData: Bool { lock.lock(); defer { lock.unlock() }; return _gotData }

    /// 第一次收到数据时返回 true（只取消一次）。
    func markGotData() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_gotData else { return false }
        _gotData = true
        return true
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
#endif
