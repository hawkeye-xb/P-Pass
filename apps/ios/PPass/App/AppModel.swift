import Foundation
import PPassCore
import SwiftUI

/// 整个 App 的状态（iOS 16：ObservableObject，不用 Observation）。界面只读这里，动作经 Backend 端口下去。
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        /// 没配对过：欢迎页 → 扫码 / 手动输入 → 配对状态页。
        case onboarding
        /// 首次配对成功：选相册（firstTime）。
        case chooseAlbums
        /// 首次选完相册：「N 张照片，正在回家」。
        case backupStarted(count: Int64)
        case main
    }

    enum Tab: Hashable { case photos, settings }

    let backend: Backend
    @Published var phase: Phase
    @Published var tab: Tab = .photos
    @Published private(set) var facts = FlowFacts()
    @Published private(set) var access: MediaAccess = .full
    @Published private(set) var pairing: PairingStatus = .notPaired
    @Published private(set) var scope: Set<String>?
    /// #343：首页常驻告示（已解析成当前语言的句子）。
    @Published private(set) var promise: [String] = []
    @Published var commandInFlight = false

    init(backend: Backend) {
        self.backend = backend
        let status = backend.pairing.status()
        phase = status == .notPaired ? .onboarding : .main
        refresh()
        backend.engine.observe { [weak self] in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        facts = backend.engine.facts()
        access = backend.media.access()
        pairing = backend.pairing.status()
        scope = backend.media.savedScope()
        promise = backend.engine.promise().map { n in DiagText.resolve(n.key, vars: n.vars) ?? n.key }
    }

    var pairingLost: Bool { if case .lost = pairing { return true } else { return false } }
    var desktopName: String? {
        switch pairing {
        case .paired(let n), .lost(let n): return n
        case .notPaired: return nil
        }
    }

    /// 范围从未保存或保存了空集：一张都不在范围内（Android #541 同口径）。
    var noAlbums: Bool { (scope ?? []).isEmpty }
    var uiState: BackupUiState { HomeProjection.backupUiState(facts, noAlbums: noAlbums) }
    var triplet: BackupTriplet? { HomeProjection.triplet(facts, scopeSaved: scope != nil) }

    func pauseOrResume() {
        commandInFlight = true
        Task {
            await backend.engine.pauseOrResume()
            commandInFlight = false
            refresh()
        }
    }

    func retry() { Task { await backend.engine.retryFailed(); refresh() } }

    /// 配对成功后的去向：以前连过这台电脑 → 首页；否则去选相册（Android 同语义）。
    func paired(firstTime: Bool) {
        refresh()
        phase = firstTime ? .chooseAlbums : .main
    }

    func albumsChosen(_ selected: Set<String>, known: Set<String>, firstTime: Bool) {
        Task {
            await backend.media.saveScope(selected, known: known)
            refresh()
            if firstTime {
                phase = .backupStarted(count: facts.inScopeTotal ?? 0)
            }
            await backend.engine.wake()
            refresh()
        }
    }

    func startOver() {
        refresh()
        phase = .onboarding
    }
}
