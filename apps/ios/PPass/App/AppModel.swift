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
    @Published private(set) var wifiOnly = true
    @Published private(set) var autoBackup = true
    @Published private(set) var notifyOnFailure = true
    /// 当前这张字节上一次前进的时刻（用来判「N 秒没有新数据」）。
    private(set) var transferMark: (orderId: Int64, bytes: Int64, at: Date)?

    init(backend: Backend) {
        self.backend = backend
        let status = backend.pairing.status()
        phase = status == .notPaired ? .onboarding : .main
        refresh()
        backend.engine.observe { [weak self] in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        facts = backend.engine.facts()
        if let v = facts.view, let id = v.currentOrderId {
            if transferMark?.orderId != id || transferMark?.bytes != v.currentBytesSent { transferMark = (id, v.currentBytesSent, Date()) }
        } else { transferMark = nil }
        access = backend.media.access()
        pairing = backend.pairing.status()
        scope = backend.media.savedScope()
        wifiOnly = backend.engine.wifiOnly()
        autoBackup = backend.engine.autoBackup()
        notifyOnFailure = backend.engine.notifyOnFailure()
        promise = backend.engine.promise().map { n in DiagText.resolve(n.key, vars: n.vars) ?? n.key }
    }

    func setNotifyOnFailure(_ on: Bool) { backend.engine.setNotifyOnFailure(on); notifyOnFailure = on }

    /// 「取消剩余 N 张」行的 N（Android cancelRemainingRowCount）：只在已暂停 / 等待中、配对没失效、确有剩余时出现。
    var cancelRemainingCount: Int64? {
        guard !pairingLost, facts.state == .paused || facts.state == .waiting else { return nil }
        return facts.remaining.flatMap { $0 > 0 ? $0 : nil }
    }

    func cancelRemaining(_ snapshot: RemainingSnapshot) {
        Task { _ = await backend.engine.cancelRemaining(snapshot); refresh() }
    }

    func restoreSkipped() { Task { await backend.engine.restoreSkipped(); refresh() } }
    func acknowledgeMissingSource() { backend.engine.acknowledgeMissingSource(); refresh() }

    func setAutoBackup(_ on: Bool) { backend.engine.setAutoBackup(on); autoBackup = on }
    func setWifiOnly(_ on: Bool) { backend.engine.setWifiOnly(on); wifiOnly = on }

    /// 距上次确认可达的整天数；从未确认过 = nil（不编造天数，走兜底文案）。取前台心跳最近一次确认桌面可达的时间
    /// （#977，Android `SentinelStore.lastReachableAt`）——不是最近一次收到照片：一直可达但没有新照片，天数不该增长。
    var daysSinceLastReachable: Int? {
        let t = facts.lastReachableAt
        guard t > 0 else { return nil }
        return Int((Int64(Date().timeIntervalSince1970 * 1000) - t) / 86_400_000)
    }

    var pairedAtMs: Int64? { backend.pairing.pairedAtMs() }

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

    /// 主动断开：成功后回到欢迎页，可以重新扫码。
    func disconnect() async {
        await backend.pairing.disconnect()
        refresh()
        tab = .photos
        phase = .onboarding
    }

    func startOver() {
        refresh()
        phase = .onboarding
    }
}
