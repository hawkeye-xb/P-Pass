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

    /// 同一份映射给通知用（PPassCore 的三档）。
    static func tier(_ level: PhotoAccessLevel) -> MediaAccessTier {
        switch map(level) {
        case .full: return .full
        case .partial: return .partial
        case .none: return .none
        }
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

    func existingAlbumIds() async -> Set<String>? {
        guard access() == .full else { return nil }
        return Set(catalog.listAlbums().map(\.id))
    }

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
///
/// 发现走收件箱（PPassMedia `Inbox`，refs #958）：G 是收件箱序号的编码（`Inbox.position(of:)`），逐张推进，对齐 Android 的
/// `(GENERATION_MODIFIED, _id)`。收件箱进箱不看范围；范围与「照片还在不在」在这里取件时过滤（MediaSource 契约：只返回范围内）。
final class PhotoMediaSource: MediaSource, @unchecked Sendable {
    private let selected: @Sendable () -> Set<String>
    private let library = PhotoKitLibrary()
    private let inbox: Inbox
    private let log: @Sendable (String) -> Void

    init(selected: @escaping @Sendable () -> Set<String>, inbox: Inbox, log: @escaping @Sendable (String) -> Void) {
        self.selected = selected
        self.inbox = inbox
        self.log = log
    }

    static func inScope(bucketId: String, selected: Set<String>) -> Bool {
        !selected.isDisjoint(with: bucketId.split(separator: "\n").map(String.init))
    }

    /// 所属可选相册（每张排序）：全量对账用 `all()` 一次拼全表；取件与 lookup 用 `of(ids)` 只反查手里这几张。
    /// 两条路对同一张照片算出同一个键（PPassMedia AlbumMembershipIT 在真 PhotoKit 上逐张核对）。
    private var membership: AlbumMembership { AlbumMembership(library: library) }

    /// 照片库里还在的那些 id 的快照（按传入顺序；查不到的略过）。[positions] 给出每一项的发现位置（与 ids 一一对应）。
    private func snapshots(_ ids: [String], members: [String: [String]], positions: [DiscoveryPosition?]? = nil) -> [MediaSnapshot] {
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }
        return ids.indices.compactMap { i in
            let id = ids[i]
            guard let a = byId[id] else { return nil }
            let content = readOriginalContent(of: a, resources: PHAssetResource.assetResources(for: a))
            if content.degraded { log("media: source version degraded for \(id) (original resource size unreadable); falls back to modification time") }
            return MediaSnapshot(mediaId: id, sourceVersion: content.version,
                                 bucketId: AlbumMembership.key(members[id]), position: positions?[i] ?? nil)
        }
    }

    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        let members = membership.all()
        let chosen = selected()
        let ids = members.filter { !chosen.isDisjoint(with: $0.value) }.keys
            .filter { id in after.map { Array($0.utf8).lexicographicallyPrecedes(Array(id.utf8)) } ?? true }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return snapshots(Array(ids.prefix(limit)), members: members)
    }

    /// 发现：收件箱里 `seq > G` 的行，按 seq；只留照片库里还在、且在范围内的，每张带自己的位置（它的 seq）。
    /// 不够 [limit] 张就接着往后翻，直到凑够或读完——前一页全在范围外时不能返回空，否则后面的新照片会卡住。
    /// G 解不出（长度不对）按 0 处理。令牌失效由收件箱自己处理（重置令牌、缺口交给对账），这里不会抛 DiscoveryCursorExpired。
    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        var after = Inbox.seq(fromPosition: position.raw)
        var out: [MediaSnapshot] = []
        let chosen = selected()
        while out.count < limit {
            try Task.checkCancellation()
            let rows = try inbox.entries(after: after, limit: limit)
            guard let last = rows.last else { break }
            after = last.seq
            let m = membership.of(rows.map(\.assetId))
            let kept = rows.filter { !chosen.isDisjoint(with: m[$0.assetId] ?? []) }
            out += snapshots(kept.map(\.assetId), members: m, positions: kept.map { DiscoveryPosition(raw: Inbox.position(of: $0.seq)) })
        }
        return Array(out.prefix(limit))
    }

    /// G 重置（首次、换电脑、照片库换了）：收件箱当前最大序号；收件箱顺带清掉 `seq <= 它` 的行。
    func currentPosition() async throws -> DiscoveryPosition { DiscoveryPosition(raw: Inbox.position(of: try inbox.currentPosition())) }

    /// nil 是契约里的「说不出」，不是占位：PhotoKit 没有对外的照片库身份（06-ios-variants O-03 / D-07 登记了查证过程：
    /// 令牌里的 store UUID 在模拟器 erase 前后不变，认不出换库）。换库的兜底是 `preciseDiscovery = false`：每个对账轮都扫。
    func libraryIdentity() async throws -> String? { nil }

    func lookup(_ mediaId: String) async throws -> MediaDetails? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [mediaId], options: nil).firstObject else { return nil }
        guard let snap = snapshots([mediaId], members: membership.of([mediaId])).first else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let content = readOriginalContent(of: asset, resources: resources)
        let res = (content.resourceIndex ?? 0) < resources.count ? resources[content.resourceIndex ?? 0] : nil
        let size = content.size ?? 0
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
