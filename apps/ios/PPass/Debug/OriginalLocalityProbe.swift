#if DEBUG
import Foundation
import Photos
import PPassCore
import PPassMedia

/// 仅 DEBUG（#337 / #1016 真机取证）：启动时记下测试文件的状态。原图在不在本机用 PPassMedia
/// `PhotoKitOriginalSource.isLocal`（公开 API、不触发下载；生产取原图时也用它，#1092）。
enum OriginalLocalityProbe {
    /// 启动时把 #337 的测试文件（原始文件名以 `ppass-test-` 开头，程序生成、经 Mac「照片」传进 iCloud）逐个记一行：
    /// 标签（A/B/C）、脱敏 id、媒体类型、资源类型、要备份的那份资源在不在本机、内容版本（#1016）、修改时间。
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
                let content = await OriginalContentReader().read(asset, resources: resources)
                let selected = content.resourceIndex.map { resources[$0] }
                let local = await selected.asyncMap { await PhotoKitOriginalSource.isLocal($0) } ?? nil
                let modified = Int64((asset.modificationDate ?? .distantPast).timeIntervalSince1970)
                // 所属用户相册的子类型（不写相册名）：看测试相册有没有同步到手机。
                var albums: [String] = []
                PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                    .enumerateObjects { c, _, _ in albums.append(String(c.assetCollectionSubtype.rawValue)) }
                AppLog.log("probe: test=\(label) \(LogRedact.id(asset.localIdentifier)) mediaType=\(asset.mediaType.rawValue) "
                    + "resources=[\(resources.map { String($0.type.rawValue) }.joined(separator: ","))] "
                    + "selected=\(selected.map { String($0.type.rawValue) } ?? "-") local=\(local.map { $0 ? "yes" : "no" } ?? "unknown") "
                    + "version=\(content.version) degraded=\(content.degraded) modified=\(modified) "
                    + "userAlbums=[\(albums.joined(separator: ","))]")
            }
        }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
#endif
