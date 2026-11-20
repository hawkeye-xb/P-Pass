@testable import PPassCore
import PPassMedia
import XCTest
@testable import PPass

/// #1259：系统还没问过照片权限时，媒体源不碰 PhotoKit（第一次用 PhotoKit 取资源 / 读变更令牌会自动弹系统框，
/// 配对后引擎那一轮会在配对页上抢先弹出，系统框只该由选范围页弹）。范围空集同样不发查询（FIX-T6）。
/// 反证：去掉 `PhotoMediaSource` 里的 accessDecided 守卫，currentPosition 会读变更令牌，`history.calls` 不为 0，红。
final class PhotoMediaSourceAccessTests: XCTestCase {
    /// 被读就记一笔：断言它一次都没被读。
    private final class RecordingHistory: ChangeHistoryReading, @unchecked Sendable {
        var calls = 0
        func currentToken() throws -> ChangeToken { calls += 1; throw ChangeHistoryError.other(code: 0, domain: "test") }
        func changes(since token: ChangeToken) throws -> [ChangeRecord] { calls += 1; return [] }
    }

    private func source(decided: Bool, fullAccess: Bool = true, selected: Set<String>) throws -> (PhotoMediaSource, RecordingHistory) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let history = RecordingHistory()
        let inbox = try Inbox(path: dir.appendingPathComponent("inbox.db").path, history: history)
        return (PhotoMediaSource(selected: { selected }, since: { .all }, inbox: inbox, accessDecided: { decided },
                                 absenceTrusted: { fullAccess }, log: { _ in }), history)
    }

    func testUndecidedAccessNeverTouchesPhotoKit() async throws {
        let (media, history) = try source(decided: false, selected: ["recents"])
        let position = try await media.currentPosition()
        XCTAssertEqual(Inbox.seq(fromPosition: position.raw), 0)
        let scanned = try await media.inScope(after: nil, limit: 10)
        XCTAssertEqual(scanned, [])
        let changed = try await media.changes(after: position, limit: 10)
        XCTAssertEqual(changed, [])
        XCTAssertEqual(history.calls, 0, "没问过照片权限：不读变更令牌")
    }

    func testEmptyScopeSendsNoQuery() async throws {
        let (media, history) = try source(decided: true, selected: [])
        let scanned = try await media.inScope(after: nil, limit: 10)
        XCTAssertEqual(scanned, [])
        let changed = try await media.changes(after: DiscoveryPosition(raw: Inbox.position(of: 0)), limit: 10)
        XCTAssertEqual(changed, [])
        XCTAssertEqual(history.calls, 0)
    }

    /// limited / denied 都只能看到部分或看不到照片，缺席不能证明删除；full 才返回可信集合。
    /// 反证：去掉 existingIds 的 absenceTrusted 守卫，limited 返回空集而不是 nil，红。
    func testExistingIdsAreUnknownWithoutFullPhotoAccess() async throws {
        let (limited, _) = try source(decided: true, fullAccess: false, selected: ["recents"])
        let limitedIds = try await limited.existingIds(["photo:1"])
        XCTAssertNil(limitedIds)

        let (full, _) = try source(decided: true, fullAccess: true, selected: ["recents"])
        let fullIds = try await full.existingIds([])
        XCTAssertEqual(fullIds, [])
    }

    private final class FakeAuthorization: PhotoAuthorizationProviding {
        var level: PhotoAccessLevel
        var requests = 0
        init(_ level: PhotoAccessLevel) { self.level = level }
        func currentLevel() -> PhotoAccessLevel { level }
        func requestFullAccess() async -> PhotoAccessLevel { requests += 1; return level }
    }

    func testAlbumListingDoesNotRequestAccessOrExposeMetadataWithoutFullAccess() async throws {
        for level in [PhotoAccessLevel.notDetermined, .denied, .restricted] {
            let auth = FakeAuthorization(level)
            var reads = 0
            let library = LiveMediaLibrary(scopeStore: { fatalError("本用例不读范围") }, auth: auth, albumListing: {
                reads += 1
                return [AlbumBucket(id: "secret", name: "Secret", count: 1, isCameraAlbum: false)]
            })
            let albums = try await library.albums()
            XCTAssertEqual(albums, [], "\(level) 不应读取相册名称或数量")
            XCTAssertEqual(reads, 0, "\(level) 不得触碰目录")
            XCTAssertEqual(auth.requests, 0, "进入范围页不得主动请求权限：\(level)")
        }
    }

    func testLimitedAccessStillListsTheAllowedAlbums() async throws {
        let expected = AlbumBucket(id: "allowed", name: "Allowed", count: 2, isCameraAlbum: false)
        let library = LiveMediaLibrary(scopeStore: { fatalError("本用例不读范围") }, auth: FakeAuthorization(.limited), albumListing: { [expected] })
        let albums = try await library.albums()
        XCTAssertEqual(albums.map(\.id), [expected.id], "部分授权沿用旧可见相册，不能当成无权限")
    }

    func testExplicitPhotoActionIsTheOnlyAccessRequest() async {
        let auth = FakeAuthorization(.notDetermined)
        let library = LiveMediaLibrary(scopeStore: { fatalError("本用例不读范围") }, auth: auth)
        _ = await library.requestAccess()
        XCTAssertEqual(auth.requests, 1)
    }

    /// #1811 评审：状态保留——已保存的相册在编辑态里全部保留（含当前列表里看不见的），权限恢复后重新可见；
    /// 从未保存则一律空。
    /// 反证：恢复「看不见的已保存相册不进编辑态」，第一条红。
    func testInitialSelectionKeepsInvisibleSavedAlbums() {
        let hidden = BucketScreen.initialSelectionWithUnavailable(saved: ["saved-album"], availableAlbums: [], cameraAlbum: nil)
        XCTAssertEqual(hidden, ["saved-album"], "看不见的已保存相册也要保留在编辑态（不能静默丢已存范围）")
        let visible = BucketScreen.initialSelectionWithUnavailable(saved: ["saved-album"], availableAlbums: ["saved-album"],
                                                                   cameraAlbum: nil)
        XCTAssertEqual(visible, ["saved-album"], "可见相册仍按同一选中语义处理")
        XCTAssertEqual(BucketScreen.initialSelectionWithUnavailable(saved: nil, availableAlbums: ["recents"],
                                                                    cameraAlbum: "recents"),
                       [], "从未保存：仍然为空")
    }

    /// #1811（评审）：没有存过的范围一律空——相机相册即使显式可用 / 显式传入也不预选；
    /// 有保存记录时也不预选新相册，只保留已保存的相册。
    /// 反证：恢复 `ScopePolicy.initialSelection` 的「saved==nil 预选相机相册」，第一条红。
    func testInitialSelectionNeverPreselectsCameraAlbum() {
        XCTAssertEqual(BucketScreen.initialSelectionWithUnavailable(saved: nil, availableAlbums: ["recents", "favorites"],
                                                                    cameraAlbum: "recents"),
                       [], "没保存过就不预选相机相册")
        XCTAssertEqual(BucketScreen.initialSelectionWithUnavailable(saved: ["mine"], availableAlbums: ["mine", "recents"],
                                                                    cameraAlbum: "recents"),
                       ["mine"], "有保存记录：不预选相机相册，只保留已保存的")
    }

    /// #1811 评审：刷新按「已保存 / 本次未保存」区分——
    /// 已保存相册即使在 none / albums 为空时也留在 checked（full 恢复后重新可见）；本次未保存勾选只在能展示时保留；
    /// 用户主动取消的已保存相册不会被刷新加回。只改编辑态，不写持久 scope。
    /// 反证：把已保存相册按可见性过滤，第一条（none）红；把「不在 current 就加回」，取消一条红。
    func testReloadKeepsSavedAlbumsAndDropsInvisibleUnsavedOnes() {
        let saved: Set<String> = ["a"]
        let current: Set<String> = ["folder:draft", "a", "b"]

        let partial = BucketScreen.selectionForReload(current: current, saved: saved, availableAlbums: ["a", "b"],
                                                      availableFolders: ["folder:draft"], photoAccess: .partial)
        XCTAssertEqual(partial, ["folder:draft", "a", "b"], "partial：已保存 + 能展示的本次勾选都保留")

        let partialHidden = BucketScreen.selectionForReload(current: current, saved: saved, availableAlbums: ["a"],
                                                            availableFolders: ["folder:draft"], photoAccess: .partial)
        XCTAssertEqual(partialHidden, ["folder:draft", "a"], "partial：看不见的本次勾选从编辑态移除")

        let none = BucketScreen.selectionForReload(current: current, saved: saved, availableAlbums: [],
                                                   availableFolders: ["folder:draft"], photoAccess: .none)
        XCTAssertEqual(none, ["folder:draft", "a"], "none 且 albums() 为空：已保存的 a 仍在，本次未保存勾选移除")

        let backToFull = BucketScreen.selectionForReload(current: none, saved: saved, availableAlbums: ["a", "b"],
                                                         availableFolders: ["folder:draft"], photoAccess: .full)
        XCTAssertEqual(backToFull, ["folder:draft", "a"], "full 恢复后已保存的 a 重新可见")

        let cancelled: Set<String> = ["folder:draft"]
        let afterCancel = BucketScreen.selectionForReload(current: cancelled, saved: saved, availableAlbums: ["a"],
                                                          availableFolders: ["folder:draft"], photoAccess: .full)
        XCTAssertEqual(afterCancel, ["folder:draft"], "用户已主动取消的已保存相册不会被刷新加回")

        let removedFolder = BucketScreen.selectionForReload(current: current, saved: saved, availableAlbums: ["a"],
                                                            availableFolders: [], photoAccess: .partial)
        XCTAssertEqual(removedFolder, ["a"], "已移除目录不能靠刷新复活")
    }

    /// #1811 评审：权限切换后保存不会误删原范围——编辑态保留着不可见的已保存相册，原样保存时落盘不变。
    /// 反证：把初始选择改成「只保留可见相册」，保存端收到空集即删掉 a，本断言红。
    func testSavingAfterPermissionRoundTripKeepsSavedScope() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackupScopeStore(directory: dir, daemonNodeId: "scope-round-trip")
        try store.saveScope(selected: ["a"], allCurrent: ["a"], since: .all)
        let library = LiveMediaLibrary(scopeStore: { store }, auth: FakeAuthorization(.limited))

        let initial = BucketScreen.initialSelectionWithUnavailable(saved: ["a"], availableAlbums: [], cameraAlbum: nil)
        XCTAssertEqual(initial, ["a"])
        let afterNone = BucketScreen.selectionForReload(current: initial, saved: ["a"], availableAlbums: [],
                                                        availableFolders: [], photoAccess: .none)
        let afterFull = BucketScreen.selectionForReload(current: afterNone, saved: ["a"], availableAlbums: ["a"],
                                                        availableFolders: [], photoAccess: .full)
        XCTAssertEqual(afterFull, ["a"], "full→none→full 后 a 仍在编辑态")

        try await library.saveScope(afterFull, known: ["a"], since: .all)
        XCTAssertEqual(try store.selectedBucketIds(), ["a"], "原样保存不会误删已保存范围")
    }

    func testEmptySelectionIsAllowedWithoutAnEmptySelectionMessage() throws {
        XCTAssertEqual(BucketScreen.initialSelectionWithUnavailable(saved: [], availableAlbums: ["recents"], cameraAlbum: "recents"), [])
        let source = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Home/BucketScreen.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("bucket_no_selection"))
        XCTAssertFalse(source.contains("sendAllowedPhotos()"), "授权不等于发起单次传输")
    }

    /// #1811：权限两态——有限授权与拒绝在范围页是同一套「相册未完整授权」，相册不进自动范围，文件夹照常。
    /// 未完整授权时相册卡片只显示当前编辑态里选中的（已保存 + 本次勾选），保证没有隐藏、无法取消的勾选。
    /// 反证：`notice(for:)` 把 `.partial` 当可选项（旧行为），本组红。
    func testIncompletePhotoAccessUsesOneNoticeState() {
        XCTAssertEqual(BucketScreen.notice(for: .partial), BucketScreen.notice(for: .none))
        XCTAssertEqual(BucketScreen.notice(for: .partial), .noAccess)
        XCTAssertEqual(BucketScreen.notice(for: .full), .none)
        let a = AlbumBucket(id: "a", name: "A", count: 1, isCameraAlbum: false)
        let b = AlbumBucket(id: "b", name: "B", count: 2, isCameraAlbum: false)
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], checked: ["a"], photoAccess: .partial).map(\.id), ["a"],
                       "未完整授权只显示 checked 里的相册")
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], checked: ["a", "b"], photoAccess: .partial).map(\.id), ["a", "b"],
                       "full→partial 时本次勾选（未保存）的 b 也保持可见可取消")
    }

    func testSavingFolderScopeKeepsInvisibleSavedAlbums() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackupScopeStore(directory: dir, daemonNodeId: "scope-access")
        try store.saveScope(selected: ["a", "folder:f1"], allCurrent: ["a", "folder:f1"], since: .all)
        let library = LiveMediaLibrary(scopeStore: { store }, auth: FakeAuthorization(.limited))

        // 相册不可见时只改文件夹：旧相册不是用户明确取消，必须保留。
        try await library.saveScope(["folder:f1"], known: ["folder:f1"], since: .all)
        XCTAssertEqual(try store.selectedBucketIds(), ["a", "folder:f1"])

        // 反证：相册仍在可见来源里、但未勾选，才是明确取消。
        try await library.saveScope(["folder:f1"], known: ["a", "folder:f1"], since: .all)
        XCTAssertEqual(try store.selectedBucketIds(), ["folder:f1"])
    }

    /// #1811 评审：混合范围 [a, folder:f] 在 partial 下能看到并取消 a；保存后成为纯文件夹并已提交。
    /// 反证：`visibleAlbums` 不显示 checked 里的相册（旧「未完整授权全隐藏」），第一步红；保存端退回「不可见就保留」，第二步红。
    func testMixedScopeCanCancelSavedAlbumUnderPartialAccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackupScopeStore(directory: dir, daemonNodeId: "scope-mixed-cancel")
        try store.saveScope(selected: ["a", "folder:f"], allCurrent: ["a", "folder:f"], since: .all)
        let library = LiveMediaLibrary(scopeStore: { store }, auth: FakeAuthorization(.limited))

        let album = AlbumBucket(id: "a", name: "A", count: 2, isCameraAlbum: false)
        let newAlbum = AlbumBucket(id: "b", name: "B", count: 9, isCameraAlbum: false)
        let visible = BucketScreen.visibleAlbums([album, newAlbum], checked: ["a", "folder:f"], photoAccess: .partial)
        XCTAssertEqual(visible.map(\.id), ["a"], "有限授权下 checked 里的相册仍显示（可取消），没勾的新相册不显示")

        // 用户在界面上取消 a 再保存：a 在可见来源里（known 带 a），落盘成为纯文件夹并提交。
        try await library.saveScope(["folder:f"], known: ["a", "folder:f"], since: .all)
        XCTAssertEqual(try store.selectedBucketIds(), ["folder:f"])
    }

    /// #1811 评审：规则初值——savedScope 读失败不得落关（保留「尚未初始化」），下次能读到真实范围再按现状初始化；
    /// 已有存值不覆盖。
    /// 反证：恢复旧写法 `(try? savedScope()) ?? nil`（读失败当 nil），第一条断言红。
    func testAutoRuleInitDefersWhenScopeUnreadable() throws {
        struct Boom: Error {}
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = AutoBackupRulePrefs(directory: dir)

        XCTAssertNil(LiveBackend.initializeAutoRuleIfAbsent(prefs, access: .full, readScope: { throw Boom() }),
                     "读失败：这次不初始化")
        XCTAssertNil(prefs.stored(), "读失败不能落关")

        XCTAssertEqual(LiveBackend.initializeAutoRuleIfAbsent(prefs, access: .full, readScope: { ["a"] }), true,
                       "下次读到非空范围：按现状开")
        XCTAssertEqual(prefs.stored(), true)

        XCTAssertEqual(LiveBackend.initializeAutoRuleIfAbsent(prefs, access: .full, readScope: { nil }), true,
                       "已有存值不被覆盖")
        XCTAssertEqual(prefs.stored(), true)
    }

    /// #1811 评审：成功读到 nil / 空集按定案关；非完整授权不读范围、直接关。
    func testAutoRuleInitOffForNilEmptyScopeOrIncompleteAccess() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        let nilDir = base.appendingPathComponent("nil")
        try FileManager.default.createDirectory(at: nilDir, withIntermediateDirectories: true)
        let nilPrefs = AutoBackupRulePrefs(directory: nilDir)
        XCTAssertEqual(LiveBackend.initializeAutoRuleIfAbsent(nilPrefs, access: .full, readScope: { nil }), false,
                       "从未保存范围 ⇒ 关")
        XCTAssertEqual(nilPrefs.stored(), false)

        let emptyDir = base.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyPrefs = AutoBackupRulePrefs(directory: emptyDir)
        XCTAssertEqual(LiveBackend.initializeAutoRuleIfAbsent(emptyPrefs, access: .full, readScope: { [] }), false,
                       "空集 ⇒ 关")
        XCTAssertEqual(emptyPrefs.stored(), false)

        let partialDir = base.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partialDir, withIntermediateDirectories: true)
        let partialPrefs = AutoBackupRulePrefs(directory: partialDir)
        XCTAssertEqual(LiveBackend.initializeAutoRuleIfAbsent(partialPrefs, access: .partial, readScope: { ["a"] }), false,
                       "非完整授权：不读范围，直接关")
        XCTAssertEqual(partialPrefs.stored(), false)
    }

    /// #1933 缺陷 1：曾授予照片权限（inbox.db 已有 token）后系统改回 .denied / .restricted 时，
    /// PhotoMediaSource 不再碰 PhotoKit inbox（不抛 UNEXPECTED_ERROR），混合范围下目录来源仍可正常扫描。
    /// 反证：恢复默认 accessDecided 为 `currentLevel() != .notDetermined`，.denied/.restricted 返回 true 并调用 inbox 抛错，本用例红。
    func testDeniedOrRestrictedPhotoAccessDoesNotTouchInboxAndLetsFolderScanContinue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 先用一次有效历史在 inbox.db 写下旧 token（模拟曾经授予完整照片权限）
        final class SeedHistory: ChangeHistoryReading, @unchecked Sendable {
            func currentToken() throws -> ChangeToken { ChangeToken(archived: Data("seed-token".utf8)) }
            func changes(since token: ChangeToken) throws -> [ChangeRecord] { [] }
        }
        let inboxPath = dir.appendingPathComponent("inbox.db").path
        let seededInbox = try Inbox(path: inboxPath, history: SeedHistory())
        _ = try seededInbox.currentPosition()

        // 切回 .denied / .restricted 后，底层 PhotoKit 历史一旦被调就会抛错（真实系统报 UNEXPECTED_ERROR）
        for level in [PhotoAccessLevel.denied, .restricted] {
            let history = RecordingHistory()
            let inbox = try Inbox(path: inboxPath, history: history)
            let photo = PhotoMediaSource(
                selected: { ["album-1", "folder:f1"] },
                since: { .all },
                inbox: inbox,
                accessDecided: { PhotoMediaSource.canReadPhotoKit(level) },
                absenceTrusted: { level == .full },
                log: { _ in }
            )

            // 混合范围里的目录来源
            let folderDir = dir.appendingPathComponent("folder-\(level.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folderDir.appendingPathComponent("shot.jpg"))
            let registryDir = dir.appendingPathComponent("reg-\(level.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
            let registry = FolderRegistry(directory: registryDir, logger: NoopLogger())
            let sourceId = try registry.addFolder(at: folderDir, displayName: "Samples")
            let folderBucket = FolderMediaSource.bucketId(sourceId: sourceId)
            let folderSource = FolderMediaSource(
                registry: registry,
                sourceId: sourceId,
                directory: registryDir,
                logger: NoopLogger(),
                scope: { (["album-1", folderBucket], ["album-1", folderBucket], .all) }
            )
            let composite = CompositeMediaSource(library: photo, others: [folderSource])

            let pos = try await composite.currentPosition()
            let changed = try await composite.changes(after: pos, limit: 10)
            XCTAssertEqual(changed, [], "\(level) 下 PhotoKit 增量不抛错且为空")
            let scanned = try await composite.inScope(after: nil, limit: 10)
            XCTAssertEqual(scanned.count, 1, "\(level) 下混合范围的文件夹条目仍可正常扫描")
            XCTAssertTrue(scanned[0].mediaId.hasPrefix("folder:\(sourceId):"))
            XCTAssertEqual(history.calls, 0, "\(level) 下不得触碰 PhotoKit inbox")
        }
    }

    /// #1933 缺陷 2：folder-only（仅选文件夹、未选任何相册）且照片权限非完整时，inScopeTotal 应返回文件夹实际总数，
    /// 不再返回 nil 导致首页投影落入 .unreadable（「无法读取相册里的照片数量」）；
    /// 同时保留含相册且照片未完整授权时返回 nil 的原行为。
    /// 反证：恢复 inScopeTotal 开头写死 `guard access() == .full else { return nil }`，folder-only 在 denied/limited/notDetermined 下返回 nil，本用例红。
    func testInScopeTotalCountsFolderOnlyWithoutFullPhotoAccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-total-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let folderDir = dir.appendingPathComponent("Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folderDir.appendingPathComponent("a.jpg"))
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folderDir.appendingPathComponent("b.jpg"))

        let registry = FolderRegistry(directory: dir, logger: NoopLogger())
        let sourceId = try registry.addFolder(at: folderDir, displayName: "Samples")
        let folderBucket = FolderMediaSource.bucketId(sourceId: sourceId)

        let store = BackupScopeStore(directory: dir, daemonNodeId: "folder-only-total")
        try store.saveScope(selected: [folderBucket], allCurrent: [folderBucket], since: .all)

        for level in [PhotoAccessLevel.denied, .limited, .notDetermined, .restricted] {
            let library = LiveMediaLibrary(scopeStore: { store }, auth: FakeAuthorization(level))
            let total = await library.inScopeTotal(folderCount: { selected, since in
                await LiveBackend.folderInScopeCount(selected: selected, since: since,
                                                     known: library.knownAlbums(),
                                                     registry: registry, directory: dir, logger: NoopLogger())
            })
            XCTAssertEqual(total, 2, "folder-only 在 \(level) 下应返回文件夹实际总数，不返回 nil")

            let facts = FlowFacts(view: EngineSnapshot(state: .idle, pending: 0), confirmed: 2, inScopeTotal: total)
            let triplet = HomeProjection.triplet(facts, scopeSaved: true)
            XCTAssertNotNil(triplet, "folder-only 应产出有效 triplet")
            XCTAssertEqual(
                HomeProjection.heroRender(LiveMediaLibrary.map(level), triplet, countsReadable: true, scopeSaved: true,
                                          hasUsableSource: true, hasSelectedAlbum: false, mixedAlbumIncomplete: false),
                .triplet,
                "folder-only 在 \(level) 下首页英雄区应渲染进度数字，不得落入 .unreadable"
            )
        }

        // 含相册且照片未完整授权时，保留原行为（返回 nil）
        try store.saveScope(selected: ["album-1", folderBucket], allCurrent: ["album-1", folderBucket], since: .all)
        for level in [PhotoAccessLevel.denied, .limited, .notDetermined] {
            let library = LiveMediaLibrary(scopeStore: { store }, auth: FakeAuthorization(level))
            let total = await library.inScopeTotal(folderCount: { _, _ in 2 })
            XCTAssertNil(total, "含相册且照片未完整授权（\(level)）时仍应返回 nil")
        }
    }
}
