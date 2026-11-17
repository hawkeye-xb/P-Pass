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

    func testInitialLoadPreservesSavedAlbumsHiddenByPermission() {
        let selected = BucketScreen.initialSelectionWithUnavailable(saved: ["saved-album"], availableAlbums: [],
                                                                    cameraAlbum: nil)
        XCTAssertEqual(selected, ["saved-album"], "无权限首次加载也不能先丢失已保存相册")
        let visible = BucketScreen.initialSelectionWithUnavailable(saved: ["saved-album"], availableAlbums: ["saved-album"],
                                                                   cameraAlbum: nil)
        XCTAssertEqual(visible, ["saved-album"], "可见相册仍按同一选中语义处理")
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

    func testReloadKeepsUnsavedFolderSelectionAndInvisibleSavedAlbum() {
        let current: Set<String> = ["folder:draft", "a", "b"]
        let saved: Set<String> = ["a"]
        let reloaded = BucketScreen.selectionForReload(current: current, saved: saved,
                                                        availableAlbums: [], availableFolders: ["folder:draft"])
        XCTAssertEqual(reloaded, ["folder:draft", "a"], "授权刷新保留未保存目录和不可见的已保存相册")
        let removed = BucketScreen.selectionForReload(current: current, saved: saved,
                                                       availableAlbums: [], availableFolders: [])
        XCTAssertEqual(removed, ["a"], "已移除目录不能靠刷新复活")
    }

    /// #1811：首次进范围页没有照片权限、授权回来也不自动补默认；一个来源都没选也能保存（空范围 = 不自动备份），
    /// 页面上必须明确写「未选择任何来源」，不弹窗。相册权限 none/partial（选择隐藏）时同样要写清楚。
    /// 反证：去掉提示（`showsEmptySelectionHint` 恒 false）或恢复「相册未完整授权不显示」，第一条断言红。
    func testEmptySelectionIsExplicitAndGetsNoDefault() {
        XCTAssertTrue(BucketScreen.showsEmptySelectionHint(hasLoaded: true, checked: []))
        XCTAssertFalse(BucketScreen.showsEmptySelectionHint(hasLoaded: false, checked: []), "还没加载完不显示")
        XCTAssertFalse(BucketScreen.showsEmptySelectionHint(hasLoaded: true, checked: ["recents"]))
    }

    /// #1811：权限两态——有限授权与拒绝在范围页是同一套「相册未完整授权」，相册不进自动范围，文件夹照常。
    /// 未完整授权时相册卡片只留保存过的（供取消），不给新增。
    /// 反证：`notice(for:)` 把 `.partial` 当可选项（旧行为），本组红。
    func testIncompletePhotoAccessUsesOneNoticeState() {
        XCTAssertEqual(BucketScreen.notice(for: .partial), BucketScreen.notice(for: .none))
        XCTAssertEqual(BucketScreen.notice(for: .partial), .noAccess)
        XCTAssertEqual(BucketScreen.notice(for: .full), .none)
        let a = AlbumBucket(id: "a", name: "A", count: 1, isCameraAlbum: false)
        let b = AlbumBucket(id: "b", name: "B", count: 2, isCameraAlbum: false)
        XCTAssertEqual(BucketScreen.visibleAlbums([a, b], saved: ["a"], photoAccess: .partial).map(\.id), ["a"],
                       "有限授权不把新相册当自动来源，只留保存过的")
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
    /// 反证：`visibleAlbums` 不显示已保存相册（旧「未完整授权全隐藏」），第一步红；保存端退回「不可见就保留」，第二步红。
    func testMixedScopeCanCancelSavedAlbumUnderPartialAccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackupScopeStore(directory: dir, daemonNodeId: "scope-mixed-cancel")
        try store.saveScope(selected: ["a", "folder:f"], allCurrent: ["a", "folder:f"], since: .all)
        let library = LiveMediaLibrary(scopeStore: { store }, auth: FakeAuthorization(.limited))

        let album = AlbumBucket(id: "a", name: "A", count: 2, isCameraAlbum: false)
        let newAlbum = AlbumBucket(id: "b", name: "B", count: 9, isCameraAlbum: false)
        let visible = BucketScreen.visibleAlbums([album, newAlbum], saved: ["a", "folder:f"], photoAccess: .partial)
        XCTAssertEqual(visible.map(\.id), ["a"], "有限授权下保存过的相册仍显示（可取消），新相册不显示")

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
}
