import Foundation
import PPassCore
import UIKit

/// 演示数据（#315）。用于界面壳与模拟器截图：启动参数 / 环境变量 `PPASS_SCENARIO` 选场景，
/// 每个空态 / 加载态 / 错误态都能直接进，不靠点坐标。诊断页会如实显示「演示数据」。
enum FakeScenario: String, CaseIterable {
    case normal, sending, paused, waiting, allSafe, trouble
    case partialAccess, noAccess, noAlbums, lost, notPaired
    case timelineEmpty, timelineLoading, timelineError
    /// 设置页告示区：后台 App 刷新关着 + 有未确认的源已删除（两条告示同时出现）。
    case notices
    /// 设置页「后台备份已关闭」引导卡：后台备份关着、卡片没被关掉。
    case backgroundOff

    static var current: FakeScenario {
        DebugLaunchInput.scenario.flatMap(FakeScenario.init(rawValue:)) ?? .normal
    }
}

enum FakeBackend {
    static func make(_ s: FakeScenario = .current) -> Backend {
        let media = FakeMediaLibrary(scenario: s)
        return Backend(isDemo: true, timeline: FakeTimeline(scenario: s), live: FakeTimelineLive(), media: media,
                       pairing: FakePairing(scenario: s), engine: FakeEngine(scenario: s, media: media))
    }
}

final class FakeMediaLibrary: MediaLibrary {
    private let scenario: FakeScenario
    private var scope: Set<String>?
    private var since: BackupSince = .since(ms: Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000))
    private var known: Set<String>
    private let all: [AlbumBucket] = [
        AlbumBucket(id: "camera", name: "Recents", count: 1_284, isCameraAlbum: true),
        AlbumBucket(id: "screens", name: "Screenshots", count: 316),
        AlbumBucket(id: "family", name: "Family", count: 92),
        AlbumBucket(id: "wechat", name: "WeChat", count: 2_047),
        AlbumBucket(id: "noname", name: nil, count: 12),
        AlbumBucket(id: "trip", name: "Trip 2026", count: 58),
    ]

    init(scenario: FakeScenario) {
        self.scenario = scenario
        scope = scenario == .noAlbums ? [] : ["camera", "family"]
        known = ["camera", "screens", "family", "wechat", "noname"]
    }

    func access() -> MediaAccess {
        switch scenario {
        case .partialAccess: return .partial
        case .noAccess: return .none
        default: return .full
        }
    }

    func requestAccess() async -> MediaAccess { access() }
    func albums() async throws -> [AlbumBucket] { all }
    func savedScope() throws -> Set<String>? { scope }
    func savedSince() throws -> BackupSince? { scope == nil ? nil : since }
    func knownAlbums() -> Set<String> { known }
    func existingAlbumIds() async -> Set<String>? { access() == .full ? Set(all.map(\.id)) : nil }

    func saveScope(_ selected: Set<String>, known: Set<String>, since: BackupSince) async throws {
        scope = selected
        self.since = since
        self.known = known
    }

    func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage? {
        let seed = FakeImages.stableSeed(album.id)
        return FakeImages.demoPhoto(seed: seed, longSide: side * 1.6)
            ?? FakeImages.tile(seed: seed, size: CGSize(width: side * 1.6, height: side))
    }

    var inScopeTotal: Int64 { Int64(all.filter { scope?.contains($0.id) == true }.reduce(0) { $0 + $1.count }) }
}

final class FakePairing: PairingService {
    private var current: PairingStatus

    init(scenario: FakeScenario) {
        switch scenario {
        case .notPaired: current = .notPaired
        case .lost: current = .lost(desktopName: "Home-Computer")
        default: current = .paired(desktopName: "Home-Computer")
        }
    }

    func status() -> PairingStatus { current }
    func pairedAtMs() -> Int64? { Int64(Date().addingTimeInterval(-86_400 * 12).timeIntervalSince1970 * 1000) }

    /// 演示规则：串里带 `t=deny` → 电脑拒绝；`t=expired` → 过期；`t=fail` → 连不上；其余 → 加入成功。
    func pair(code: String, onCode: @escaping PairCodeSink) async -> PairOutcome {
        await onCode(PairCodeShown(code: "482916", desktop: PairDesktopInfo(name: "Home-Computer", fingerprint: "AB12 CD34"), phoneNode: ""))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if code.contains("t=deny") { return .refused(note: nil, ownerSaidNo: true) }
        if code.contains("t=expired") { return .refused(note: .expired, ownerSaidNo: false) }
        if code.contains("t=fail") { return .failed(diagnostic: "demo: unreachable") }
        current = .paired(desktopName: "Home-Computer")
        return .joined(firstTime: true)
    }

    func cancel() async {}

    func disconnect() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        current = .notPaired
    }

    func clearLocal() async { current = .notPaired }
}

enum FakeBackendError: Error { case demoHasNoLedger }

final class FakeEngine: BackupEngine {
    private let scenario: FakeScenario
    private let media: FakeMediaLibrary
    private var paused: Bool
    private var listeners: [() -> Void] = []

    init(scenario: FakeScenario, media: FakeMediaLibrary) {
        self.scenario = scenario
        self.media = media
        paused = scenario == .paused
        auto = scenario != .backgroundOff
    }

    func facts() -> FlowFacts {
        let n = media.inScopeTotal
        var f = FlowFacts(view: EngineSnapshot(), confirmed: n, inScopeTotal: n,
                          lastSuccessAt: Int64(Date().timeIntervalSince1970 * 1000) - 42 * 60_000)
        switch scenario {
        case .sending:
            f.view = EngineSnapshot(state: .running, pending: 37, doneThisRound: 11, currentFileName: "IMG_4821.HEIC")
        case .paused:
            f.view = EngineSnapshot(state: paused ? .paused : .running, pending: 37, doneThisRound: 11,
                                    currentFileName: paused ? nil : "IMG_4821.HEIC")
        case .waiting:
            f.view = EngineSnapshot(state: .waiting, waitReason: .desktopUnreachable, pending: 37)
        case .trouble:
            f.view = EngineSnapshot(state: .idle, pending: 3)
            f.failed = 3
        case .normal:
            f.view = EngineSnapshot(state: .idle, pending: 37)
        case .notices:
            f.missingSourceUnacknowledged = 3
        default:
            break
        }
        if scenario == .paused { f.view?.state = paused ? .paused : .running }
        return f
    }

    func observe(_ onChange: @escaping () -> Void) { listeners.append(onChange) }

    func pauseOrResume() async {
        paused.toggle()
        listeners.forEach { $0() }
    }

    private var auto = true
    func autoBackup() -> Bool { auto }
    func setAutoBackup(_ on: Bool) throws { auto = on; listeners.forEach { $0() } }
    private var cardDismissed = false
    func backgroundCardDismissed() -> Bool { cardDismissed }
    func dismissBackgroundCard() throws { cardDismissed = true; listeners.forEach { $0() } }
    private var wifi = true
    func wifiOnly() -> Bool { wifi }
    func setWifiOnly(_ on: Bool) throws { wifi = on; listeners.forEach { $0() } }
    func wake() async {}
    func retryFailed() async throws {}
    func remainingSnapshot() async throws -> RemainingSnapshot { throw FakeBackendError.demoHasNoLedger }
    func cancelRemaining(_ snapshot: RemainingSnapshot) async throws -> Int? { nil }
    func restoreSkipped() async throws {}
    func acknowledgeMissingSource() {}
    private var notify = true
    func notifyOnFailure() -> Bool { notify }
    func setNotifyOnFailure(_ on: Bool) throws { notify = on; listeners.forEach { $0() } }
    var fakeAuthorization: NotificationAuthorization = .authorized
    func notificationAuthorization() async -> NotificationAuthorization { fakeAuthorization }
    func requestNotificationAuthorization() async -> NotificationAuthorization { fakeAuthorization }
    @MainActor func openNotificationSettings() {}
    func finishOnboarding() throws {}

    func backgroundRefresh() -> BackgroundRefreshAvailability { scenario == .notices ? .denied : .available }
}

/// 演示数据没有电脑可订阅：不产生任何信号（页面行为 = 演示数据本身），状态恒为初始。
final class FakeTimelineLive: TimelineLiveFeed {
    @MainActor func observe(_ handler: @escaping @MainActor (TimelineLiveEvent) -> Void) -> UUID { handler(.state(TimelineLiveState())); return UUID() }
    @MainActor func remove(_ token: UUID) {}
    @MainActor func retry() {}
}
