import Foundation
import Photos
import PPassCore
import PPassMedia
import UIKit
import UniformTypeIdentifiers

/// 手机相册（PPassMedia）：授权三档、相册目录、备份范围（PPassCore `BackupScopeStore`，按电脑分文件）。
final class LiveMediaLibrary: MediaLibrary, @unchecked Sendable {
    typealias CoverImageCompletion = @Sendable (UIImage?, [AnyHashable: Any]?) -> Void
    typealias CoverImageRequester = @Sendable (
        _ assetId: String,
        _ targetSize: CGSize,
        _ contentMode: PHImageContentMode,
        _ options: PHImageRequestOptions,
        _ resultHandler: @escaping CoverImageCompletion
    ) -> PHImageRequestID?

    private let auth: PhotoAuthorizationProviding
    private let catalog: AlbumCatalog
    private let albumListing: (() -> [AlbumBucket])?
    private let scopeStore: () -> BackupScopeStore
    private let requestCoverImage: CoverImageRequester
    private let cancelCoverImage: @Sendable (PHImageRequestID) -> Void

    init(
        scopeStore: @escaping () -> BackupScopeStore,
        auth: PhotoAuthorizationProviding = PhotoKitAuthorization(),
        library: any PhotoLibraryReading = PhotoKitLibrary(),
        albumListing: (() -> [AlbumBucket])? = nil,
        requestCoverImage: CoverImageRequester? = nil,
        cancelCoverImage: (@Sendable (PHImageRequestID) -> Void)? = nil
    ) {
        self.scopeStore = scopeStore
        self.auth = auth
        self.catalog = AlbumCatalog(library: library)
        self.albumListing = albumListing
        self.requestCoverImage = requestCoverImage ?? { assetId, targetSize, contentMode, options, resultHandler in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
                resultHandler(nil, nil)
                return nil
            }
            return PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                resultHandler(image, info)
            }
        }
        self.cancelCoverImage = cancelCoverImage ?? { requestId in
            PHImageManager.default().cancelImageRequest(requestId)
        }
    }

    private static let albumCatalogQueue = DispatchQueue(label: "com.ppass.ios.album-catalog", qos: .userInitiated)

    /// 选备份范围封面请求配置（#1944）：只读系统本地已有的快速缩略图，绝不联网拉取 iCloud 原图。
    static func coverRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        return options
    }

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
        guard !Task.isCancelled else { return [] }
        switch auth.currentLevel() {
        case .full, .limited: break
        case .notDetermined, .denied, .restricted: return []
        }
        if let albumListing { return albumListing() }
        let box = AlbumListBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[AlbumBucket], Never>) in
                guard box.install(continuation) else { return }
                Self.albumCatalogQueue.async { [self] in
                    guard !box.isCancelled else {
                        box.complete(with: [])
                        return
                    }
                    let result = self.catalog.listAlbums().map {
                        AlbumBucket(
                            id: $0.id,
                            name: $0.title,
                            count: $0.count,
                            isCameraAlbum: $0.kind == .library,
                            coverAssetId: $0.coverAssetId
                        )
                    }
                    box.complete(with: result)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage? {
        guard let id = album.coverAssetId, !Task.isCancelled else { return nil }
        let options = Self.coverRequestOptions()
        let scale = await UIScreen.main.scale
        guard !Task.isCancelled else { return nil }
        let targetSize = CGSize(width: side * 1.6 * scale, height: side * scale)
        let box = CoverRequestBox(cancelRequest: cancelCoverImage)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                guard box.install(continuation) else { return }
                let reqId = requestCoverImage(id, targetSize, .aspectFill, options) { image, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let hasError = info?[PHImageErrorKey] != nil
                    let valid = (!cancelled && !hasError) ? image : nil
                    box.complete(with: valid)
                }
                box.setRequestId(reqId)
            }
        } onCancel: {
            box.cancel()
        }
    }

    func savedScope() throws -> Set<String>? { try scopeStore().selectedBucketIds() }
    func savedSince() throws -> BackupSince? { try scopeStore().since() }
    func knownAlbums() -> Set<String> {
        do { return try scopeStore().knownBucketIds() ?? [] } catch {
            AppLog.log("backup-scope: known albums unreadable: \(error)")
            return []
        }
    }

    func existingAlbumIds() async -> Set<String>? {
        guard access() == .full else { return nil }
        return Set(catalog.listAlbums().map(\.id))
    }

    func saveScope(_ selected: Set<String>, known: Set<String>, since: BackupSince) async throws {
        do {
            let previous = try scopeStore().selectedBucketIds() ?? []
            // 权限不可见不等于用户取消；只有当前仍可见却未勾选的相册才允许从旧范围移除。
            let invisibleSavedAlbums = previous.filter { !$0.hasPrefix("folder:") && !known.contains($0) }
            try scopeStore().saveScope(selected: selected.union(invisibleSavedAlbums), allCurrent: known.union(invisibleSavedAlbums), since: since)
        } catch {
            AppLog.log("backup-scope: save failed: \(error)")
            throw error
        }
    }

    /// 范围内总数 = 所选相册的**并集**去重（一张照片可以在多个相册里，不能按相册相加），再按时间档筛（#1263，首页分母跟着范围走）；
    /// 已选文件夹按同一时间档计入（#1933）。
    /// - 仅选文件夹（folder-only）时不依赖照片库权限，即使照片权限为 denied/limited/notDetermined/restricted 也能返回真实总数；
    /// - 只要包含相册且照片未完整授权，返回 nil（保留原有权限闸门，不给假数字）。
    func inScopeTotal(folderCount: ((Set<String>, BackupSince) async -> Int64?)? = nil) async -> Int64? {
        let selected: Set<String>
        let since: BackupSince
        do {
            guard let saved = try savedScope() else { return nil }
            selected = saved
            since = try savedSince() ?? .all
        } catch {
            AppLog.log("backup-scope: unreadable, in-scope total unknown: \(error)")
            return nil
        }
        let selectedAlbums = selected.filter { !$0.hasPrefix("folder:") }
        let hasSelectedAlbum = !selectedAlbums.isEmpty
        let hasSelectedFolder = selected.contains { $0.hasPrefix("folder:") }
        if hasSelectedAlbum {
            guard access() == .full else { return nil }
            let ids = AlbumScope(library: PhotoKitLibrary()).assetIdentifiers(inAlbums: selectedAlbums)
            let albumTotal = Int64(PhotoMediaSource.inTime(ids, since: since).count)
            guard let folderCount else { return albumTotal }
            guard let folderTotal = await folderCount(selected, since) else { return nil }
            return albumTotal + folderTotal
        }
        if hasSelectedFolder {
            return await folderCount?(selected, since)
        }
        guard access() == .full else { return nil }
        return 0
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
    private let since: @Sendable () -> BackupSince
    /// 系统问过照片权限没有（#1259）。没问过时不碰 PhotoKit：App 第一次用 PhotoKit 取资源 / 读变更令牌，系统会自动弹授权框；
    /// 配对成功后引擎那一轮会在配对页上、在用户没走到选范围页之前就把它弹出来。系统框只该由选范围页读相册列表时弹（`LiveMediaLibrary.albums`）。
    /// 没问过 = 一张照片都读不到，范围内本来就是空的。
    private let accessDecided: @Sendable () -> Bool
    private let absenceTrusted: @Sendable () -> Bool
    private let library = PhotoKitLibrary()
    private let contents = OriginalContentReader()
    private let inbox: Inbox
    private let log: @Sendable (String) -> Void

    /// 只有已获得可读照片权限（full / limited）才允许触碰 PhotoKit（含 inbox 变更历史）。
    /// - notDetermined：碰 PhotoKit 会抢先弹系统授权框（#1259）；
    /// - denied / restricted：曾授过权留有旧 token 时调 inbox 会抛错导致 UNEXPECTED_ERROR，拖垮混合范围里的目录来源（#1933）。
    static func canReadPhotoKit(_ level: PhotoAccessLevel) -> Bool {
        switch level {
        case .full, .limited: return true
        case .notDetermined, .denied, .restricted: return false
        }
    }

    init(selected: @escaping @Sendable () -> Set<String>, since: @escaping @Sendable () -> BackupSince, inbox: Inbox,
         accessDecided: @escaping @Sendable () -> Bool = { PhotoMediaSource.canReadPhotoKit(PhotoKitAuthorization().currentLevel()) },
         absenceTrusted: @escaping @Sendable () -> Bool = { PhotoKitAuthorization().currentLevel() == .full },
         log: @escaping @Sendable (String) -> Void) {
        self.selected = selected
        self.since = since
        self.accessDecided = accessDecided
        self.absenceTrusted = absenceTrusted
        self.inbox = inbox
        self.log = log
    }

    /// 范围键带拍摄时刻（`ScopeKey`，#1263）：已落库的行也能按时间档判断。
    static func inScope(bucketId: String, selected: Set<String>, since: BackupSince) -> Bool {
        ScopeKey.inScope(bucketId, selected: selected, since: since)
    }

    /// 拍摄时间优先，只有 creationDate 缺失才用 modificationDate。预查询必须保留「creationDate 为空」的候选，
    /// 否则回退项会在 snapshots 之前就被漏掉。
    static func inTime(_ ids: Set<String>, since: BackupSince) -> Set<String> {
        guard case .since(let ms) = since, !ids.isEmpty else { return ids }
        let options = PHFetchOptions()
        let start = Date(timeIntervalSince1970: Double(ms) / 1000) as NSDate
        options.predicate = NSPredicate(format: "creationDate >= %@ OR (creationDate == nil AND modificationDate >= %@)", start, start)
        var out = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: options).enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }

    static func capturedAtMs(_ asset: PHAsset) -> Int64? {
        (asset.creationDate ?? asset.modificationDate).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    /// 所属可选相册（每张排序）：全量对账用 `all()` 一次拼全表；取件与 lookup 用 `of(ids)` 只反查手里这几张。
    /// 两条路对同一张照片算出同一个键（PPassMedia AlbumMembershipIT 在真 PhotoKit 上逐张核对）。
    private var membership: AlbumMembership { AlbumMembership(library: library) }

    /// 照片库里还在的那些 id 的快照（按传入顺序；查不到的略过）。[positions] 给出每一项的发现位置（与 ids 一一对应）。
    private func snapshots(_ ids: [String], members: [String: [String]], positions: [DiscoveryPosition?]? = nil) async -> [MediaSnapshot] {
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }
        var out: [MediaSnapshot] = []
        for i in ids.indices {
            let id = ids[i]
            guard let a = byId[id] else { continue }
            let content = await contents.read(a, resources: PHAssetResource.assetResources(for: a))
            if content.degraded { log("media: source version degraded for \(LogRedact.id(id)) (edit record unreadable or no original resource); falls back to modification time") }
            out.append(MediaSnapshot(mediaId: id, sourceVersion: content.version,
                                     bucketId: ScopeKey.encode(albums: members[id] ?? [], capturedAtMs: Self.capturedAtMs(a)),
                                     position: positions?[i] ?? nil))
        }
        return out
    }

    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        let chosen = selected().filter { !$0.hasPrefix("folder:") }
        // 范围空集不发查询（对位 AlbumScope / FIX-T6）；无可读照片权限不碰 PhotoKit（#1259 / #1933）。
        guard !chosen.isEmpty, accessDecided() else { return [] }
        let members = membership.all()
        // 时间档要在截取 limit 之前筛：一页全被筛掉会被扫描当成读完（ScopeCursor：不足一页 = 到底）。
        let candidates = Set(members.filter { !chosen.isDisjoint(with: $0.value) }.keys
            .filter { id in after.map { Array($0.utf8).lexicographicallyPrecedes(Array(id.utf8)) } ?? true })
        let ids = Self.inTime(candidates, since: since())
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return await snapshots(Array(ids.prefix(limit)), members: members)
    }

    /// 发现：收件箱里 `seq > G` 的行，按 seq；只留照片库里还在、且在范围内的，每张带自己的位置（它的 seq）。
    /// 不够 [limit] 张就接着往后翻，直到凑够或读完——前一页全在范围外时不能返回空，否则后面的新照片会卡住。
    /// G 解不出（长度不对）按 0 处理。令牌失效由收件箱自己处理（重置令牌、缺口交给对账），这里不会抛 DiscoveryCursorExpired。
    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        var after = Inbox.seq(fromPosition: position.raw)
        var out: [MediaSnapshot] = []
        let chosen = selected().filter { !$0.hasPrefix("folder:") }
        guard !chosen.isEmpty, accessDecided() else { return [] }
        let window = since()
        while out.count < limit {
            try Task.checkCancellation()
            let rows = try inbox.entries(after: after, limit: limit)
            guard let last = rows.last else { break }
            after = last.seq
            let m = membership.of(rows.map(\.assetId))
            let kept = rows.filter { !chosen.isDisjoint(with: m[$0.assetId] ?? []) }
            out += await snapshots(kept.map(\.assetId), members: m, positions: kept.map { DiscoveryPosition(raw: Inbox.position(of: $0.seq)) })
                .filter { ScopeKey.inTime(capturedAtMs: ScopeKey.decode($0.bucketId).capturedAtMs, since: window) }
        }
        return Array(out.prefix(limit))
    }

    /// G 重置（首次、换电脑、照片库换了）：收件箱当前最大序号；收件箱顺带清掉 `seq <= 它` 的行。
    /// 没问过照片权限：给 0，不读变更令牌（会弹框，#1259）。没问过只可能是全新安装，收件箱是空的，高水位本来就是 0；
    /// 令牌留到第一次取件时初始化，之前的照片由保存范围触发的 SCOPE_ADDED 对账扫到。
    func currentPosition() async throws -> DiscoveryPosition {
        guard accessDecided() else { return DiscoveryPosition(raw: Inbox.position(of: 0)) }
        return DiscoveryPosition(raw: Inbox.position(of: try inbox.currentPosition()))
    }

    /// nil 是契约里的「说不出」，不是占位：PhotoKit 没有对外的照片库身份（06-ios-variants O-03 / D-07 登记了查证过程：
    /// 令牌里的 store UUID 在模拟器 erase 前后不变，认不出换库）。换库的兜底是 `preciseDiscovery = false`：每个对账轮都扫。
    func libraryIdentity() async throws -> String? { nil }

    func lookup(_ mediaId: String) async throws -> MediaDetails? {
        guard accessDecided() else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [mediaId], options: nil).firstObject else { return nil }
        guard let snap = await snapshots([mediaId], members: membership.of([mediaId])).first else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let index = selectOriginalResource(types: resources.map(\.type), mediaType: asset.mediaType)
        let res = index.map { resources[$0] }
        // 大小在取原图之前不可知（公开 API 不给，#1016）：0 = 未知，引擎以导入时的实际字节数为准。
        let size: Int64 = 0
        let mime = res.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType } ?? "application/octet-stream"
        let captured = Int64((asset.creationDate ?? asset.modificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
        return MediaDetails(snapshot: snap, fileName: res?.originalFilename ?? mediaId, mimeType: mime,
                            sizeBytes: size, captureAtMs: max(captured, 0))
    }

    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        guard absenceTrusted() else { return nil }
        var out = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: mediaIds, options: nil).enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }
}

// MARK: - 选范围相册目录与封面并发取消盒（#1944）

private final class AlbumListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[AlbumBucket], Never>?
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ c: CheckedContinuation<[AlbumBucket], Never>) -> Bool {
        let alreadyCancelled: Bool = lock.withLock {
            if cancelled {
                finished = true
                return true
            }
            continuation = c
            return false
        }
        if alreadyCancelled {
            c.resume(returning: [])
            return false
        }
        return true
    }

    func complete(with albums: [AlbumBucket]) {
        let c: CheckedContinuation<[AlbumBucket], Never>? = lock.withLock {
            guard !finished, let cont = continuation else { return nil }
            finished = true
            continuation = nil
            return cont
        }
        c?.resume(returning: albums)
    }

    func cancel() {
        let c: CheckedContinuation<[AlbumBucket], Never>? = lock.withLock {
            cancelled = true
            guard !finished, let cont = continuation else { return nil }
            finished = true
            continuation = nil
            return cont
        }
        c?.resume(returning: [])
    }
}

private final class CoverRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestId: PHImageRequestID?
    private var cancelled = false
    private var finished = false
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void

    init(cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void) {
        self.cancelRequest = cancelRequest
    }

    func install(_ c: CheckedContinuation<UIImage?, Never>) -> Bool {
        let alreadyCancelled: Bool = lock.withLock {
            if cancelled {
                finished = true
                return true
            }
            continuation = c
            return false
        }
        if alreadyCancelled {
            c.resume(returning: nil)
            return false
        }
        return true
    }

    func setRequestId(_ id: PHImageRequestID?) {
        guard let id else { return }
        let shouldCancel: Bool = lock.withLock {
            if cancelled {
                return true
            }
            if !finished {
                requestId = id
            }
            return false
        }
        if shouldCancel {
            cancelRequest(id)
        }
    }

    func complete(with image: UIImage?) {
        let c: CheckedContinuation<UIImage?, Never>? = lock.withLock {
            guard !finished, let cont = continuation else { return nil }
            finished = true
            continuation = nil
            requestId = nil
            return cont
        }
        c?.resume(returning: image)
    }

    func cancel() {
        let (c, id): (CheckedContinuation<UIImage?, Never>?, PHImageRequestID?) = lock.withLock {
            cancelled = true
            let reqId = requestId
            requestId = nil
            guard !finished, let cont = continuation else { return (nil, reqId) }
            finished = true
            continuation = nil
            return (cont, reqId)
        }
        if let id {
            cancelRequest(id)
        }
        c?.resume(returning: nil)
    }
}

