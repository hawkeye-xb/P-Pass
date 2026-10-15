import Foundation
import Photos
import PPassCore
import PPassMedia
import UIKit
import UniformTypeIdentifiers

/// 手机相册（PPassMedia）：授权三档、相册目录、备份范围（PPassCore `BackupScopeStore`，按电脑分文件）。
final class LiveMediaLibrary: MediaLibrary, @unchecked Sendable {
    private let auth = PhotoKitAuthorization()
    private let catalog = AlbumCatalog(library: PhotoKitLibrary())
    private let scopeStore: () -> BackupScopeStore

    init(scopeStore: @escaping () -> BackupScopeStore) { self.scopeStore = scopeStore }

    /// 权限三档 → 首页表达（#336：只有完整授权才显示数字、才允许「都存好了」）。没决定过也算拿不到。
    func access() -> MediaAccess { Self.map(auth.currentLevel()) }

    static func map(_ level: PhotoAccessLevel) -> MediaAccess {
        let p = PhotoAccessPresentation.of(level)
        if p.showsBackupCounts { return .full }
        return level == .limited ? .partial : .none
    }

    func requestAccess() async -> MediaAccess { Self.map(await auth.requestFullAccess()) }

    func albums() async throws -> [AlbumBucket] {
        if auth.currentLevel() == .notDetermined { _ = await auth.requestFullAccess() }
        return catalog.listAlbums().map { AlbumBucket(id: $0.id, name: $0.title, count: $0.count) }
    }

    func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage? {
        guard let id = catalog.listAlbums().first(where: { $0.id == album.id })?.coverAssetId,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let scale = await UIScreen.main.scale
        return await withCheckedContinuation { c in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side * 1.6 * scale, height: side * scale),
                                                  contentMode: .aspectFill, options: options) { image, _ in c.resume(returning: image) }
        }
    }

    func savedScope() -> Set<String>? { try? scopeStore().selectedBucketIds() }
    func knownAlbums() -> Set<String> { (try? scopeStore().knownBucketIds()) ?? [] }

    func saveScope(_ selected: Set<String>, known: Set<String>) async {
        try? scopeStore().saveScope(selected: selected, allCurrent: known)
    }

    /// 范围内总数 = 所选相册的**并集**去重（一张照片可以在多个相册里，不能按相册相加）。
    func inScopeTotal() -> Int64? {
        guard access() == .full, let selected = savedScope() else { return nil }
        return Int64(AlbumScope(library: PhotoKitLibrary()).count(inAlbums: selected))
    }
}

/// PPassCore `MediaSource` 的 PhotoKit 实现。
///
/// 范围键（`MediaSnapshot.bucketId`）按 06-ios-variants 的登记：编码这张照片所属的**相册集合**（排序后用换行连接），
/// `inScope` = 任一所属相册被选中。集合只在「可选相册」（AlbumCatalog）里算，同一张照片每次算出的键相同。
final class PhotoMediaSource: MediaSource, @unchecked Sendable {
    private let selected: @Sendable () -> Set<String>
    private let library = PhotoKitLibrary()
    private let history = PhotoKitChangeHistory()

    init(selected: @escaping @Sendable () -> Set<String>) { self.selected = selected }

    static func inScope(bucketId: String, selected: Set<String>) -> Bool {
        !selected.isDisjoint(with: bucketId.split(separator: "\n").map(String.init))
    }

    /// assetId → 所属可选相册（排序）。
    private func membership() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for album in AlbumCatalog(library: library).listAlbums() {
            for id in library.assetIdentifiers(inCollection: album.id) ?? [] { out[id, default: []].append(album.id) }
        }
        for key in out.keys { out[key]?.sort() }
        return out
    }

    private func snapshots(_ ids: [String], members: [String: [String]], position: DiscoveryPosition?) -> [MediaSnapshot] {
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }
        return ids.compactMap { id in
            guard let a = byId[id] else { return nil }
            let modified = Int64((a.modificationDate ?? a.creationDate ?? .distantPast).timeIntervalSince1970 * 1000)
            return MediaSnapshot(mediaId: id, sourceVersion: sourceVersionOf(modifiedAtMs: modified, size: 0),
                                 bucketId: (members[id] ?? []).joined(separator: "\n"), position: position)
        }
    }

    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        let members = membership()
        let chosen = selected()
        let ids = members.filter { !chosen.isDisjoint(with: $0.value) }.keys
            .filter { id in after.map { Array($0.utf8).lexicographicallyPrecedes(Array(id.utf8)) } ?? true }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return snapshots(Array(ids.prefix(limit)), members: members, position: nil)
    }

    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        switch try ChangeDiscovery(history: history).discover(since: ChangeToken(archived: position.raw)) {
        case .start:
            return []
        case .rescan:
            throw DiscoveryCursorExpired()
        case .changes(let window):
            let members = membership()
            let chosen = selected()
            let end = DiscoveryPosition(raw: window.endToken.archived)
            let ids = window.newAssetIds.filter { !chosen.isDisjoint(with: members[$0] ?? []) }
            return snapshots(Array(ids.prefix(limit)), members: members, position: end)
        }
    }

    func currentPosition() async throws -> DiscoveryPosition { DiscoveryPosition(raw: try history.currentToken().archived) }

    /// PhotoKit 没有对外的「照片库身份」——说不出来就返回 nil（不触发重置）。
    func libraryIdentity() async throws -> String? { nil }

    func lookup(_ mediaId: String) async throws -> MediaDetails? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [mediaId], options: nil).firstObject else { return nil }
        let members = membership()
        guard let snap = snapshots([mediaId], members: members, position: nil).first else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let index = selectOriginalResource(types: resources.map(\.type), mediaType: asset.mediaType) ?? 0
        let res = resources.indices.contains(index) ? resources[index] : nil
        let size = (res?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
        let mime = res.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType } ?? "application/octet-stream"
        let captured = Int64((asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000)
        return MediaDetails(snapshot: snap, fileName: res?.originalFilename ?? mediaId, mimeType: mime,
                            sizeBytes: size, captureAtMs: max(captured, 0))
    }

    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        var out = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: mediaIds, options: nil).enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }
}
