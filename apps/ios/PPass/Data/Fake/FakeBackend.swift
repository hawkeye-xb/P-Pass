import Foundation
import PPassCore
import UIKit

/// 演示数据（#315）。用于界面壳与模拟器截图：启动参数 / 环境变量 `PPASS_SCENARIO` 选场景，
/// 每个空态 / 加载态 / 错误态都能直接进，不靠点坐标。诊断页会如实显示「演示数据」。
enum FakeScenario: String, CaseIterable {
    case normal, sending, paused, waiting, allSafe, trouble
    case partialAccess, noAccess, noAlbums, lost, notPaired
    case timelineEmpty, timelineLoading, timelineError

    static var current: FakeScenario {
        let env = ProcessInfo.processInfo.environment["PPASS_SCENARIO"] ?? UserDefaults.standard.string(forKey: "PPASS_SCENARIO")
        return env.flatMap(FakeScenario.init(rawValue:)) ?? .normal
    }
}

enum FakeBackend {
    static func make(_ s: FakeScenario = .current) -> Backend {
        let media = FakeMediaLibrary(scenario: s)
        return Backend(isDemo: true, timeline: FakeTimeline(scenario: s), media: media,
                       pairing: FakePairing(scenario: s), engine: FakeEngine(scenario: s, media: media))
    }
}

final class FakeMediaLibrary: MediaLibrary {
    private let scenario: FakeScenario
    private var scope: Set<String>?
    private var known: Set<String>
    private let all: [AlbumBucket] = [
        AlbumBucket(id: "camera", name: "Camera", count: 1_284),
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
    func savedScope() -> Set<String>? { scope }
    func knownAlbums() -> Set<String> { known }

    func saveScope(_ selected: Set<String>, known: Set<String>) async {
        scope = selected
        self.known = known
    }

    func cover(_ album: AlbumBucket, side: CGFloat) async -> UIImage? {
        FakeImages.tile(seed: album.id.hashValue, size: CGSize(width: side * 1.6, height: side))
    }

    var inScopeTotal: Int64 { Int64(all.filter { scope?.contains($0.id) == true }.reduce(0) { $0 + $1.count }) }
}

final class FakePairing: PairingService {
    private var current: PairingStatus

    init(scenario: FakeScenario) {
        switch scenario {
        case .notPaired: current = .notPaired
        case .lost: current = .lost(desktopName: "Home-Mac")
        default: current = .paired(desktopName: "Home-Mac")
        }
    }

    func status() -> PairingStatus { current }
    func pairedAtMs() -> Int64? { Int64(Date().addingTimeInterval(-86_400 * 12).timeIntervalSince1970 * 1000) }

    /// 演示规则：串里带 `t=deny` → 电脑拒绝；`t=expired` → 过期；`t=fail` → 连不上；其余 → 加入成功。
    func pair(code: String) async -> PairOutcome {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if code.contains("t=deny") { return .refused(msgKey: nil, ownerSaidNo: true) }
        if code.contains("t=expired") { return .refused(msgKey: "err.pair_expired", ownerSaidNo: false) }
        if code.contains("t=fail") { return .failed(reason: "demo: unreachable") }
        current = .paired(desktopName: "Home-Mac")
        return .joined(firstTime: true)
    }

    func cancel() async {}

    func disconnect() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        current = .notPaired
    }
}

final class FakeEngine: BackupEngine {
    private let scenario: FakeScenario
    private let media: FakeMediaLibrary
    private var paused: Bool
    private var listeners: [() -> Void] = []

    init(scenario: FakeScenario, media: FakeMediaLibrary) {
        self.scenario = scenario
        self.media = media
        paused = scenario == .paused
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
    func setAutoBackup(_ on: Bool) { auto = on; listeners.forEach { $0() } }
    private var wifi = true
    func wifiOnly() -> Bool { wifi }
    func setWifiOnly(_ on: Bool) { wifi = on; listeners.forEach { $0() } }
    func wake() async {}
    func retryFailed() async {}
    func remainingSnapshot() async -> RemainingSnapshot? { nil }
    func cancelRemaining(_ snapshot: RemainingSnapshot) async -> Int? { nil }
    func restoreSkipped() async {}
    func acknowledgeMissingSource() {}
    private var notify = true
    func notifyOnFailure() -> Bool { notify }
    func setNotifyOnFailure(_ on: Bool) { notify = on; listeners.forEach { $0() } }

    func promise() -> [PromiseNotice] {
        var out = [PromiseNotice(BackupPromise.whileOpenTitle), PromiseNotice(BackupPromise.whileOpenBody)]
        if scenario == .waiting { out.append(PromiseNotice(BackupPromise.waitOpenApp)) }
        return out
    }
}
