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
        for level in [PhotoAccessLevel.notDetermined, .denied, .restricted, .limited] {
            let auth = FakeAuthorization(level)
            let library = LiveMediaLibrary(scopeStore: { fatalError("本用例不读范围") }, auth: auth)
            let albums = try await library.albums()
            XCTAssertEqual(albums, [], "\(level) 不应读取相册名称或数量")
            XCTAssertEqual(auth.requests, 0, "进入范围页不得主动请求权限：\(level)")
        }
    }

    func testExplicitPhotoActionIsTheOnlyAccessRequest() async {
        let auth = FakeAuthorization(.notDetermined)
        let library = LiveMediaLibrary(scopeStore: { fatalError("本用例不读范围") }, auth: auth)
        _ = await library.requestAccess()
        XCTAssertEqual(auth.requests, 1)
    }
}
