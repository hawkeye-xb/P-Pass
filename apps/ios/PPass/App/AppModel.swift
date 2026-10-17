import Foundation
import PPassCore
import SwiftUI

/// 一条需要用户看到的失败反馈（#971 / #972）：设置没存上、命令没执行成。界面用 alert 呈现，点掉即清。
struct UserNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

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
    /// 系统里当前实际存在的相册（nil = 没有完整授权，读不到）。「已选相册」只数已选且现存的（#983，Android #836）。
    @Published private(set) var existingAlbums: Set<String>?
    /// #343：首页常驻告示（已解析成当前语言的句子）。
    @Published private(set) var promise: [String] = []
    @Published var commandInFlight = false
    /// 最近一次失败反馈（设置写盘失败 / 命令出错）。界面 alert 绑定它。
    @Published var notice: UserNotice?
    /// 「仅 Wi‑Fi」要关：等用户在确认框里点「仍然关闭」才写盘（Android MOB-02 §三：移动网络会消耗流量）。
    @Published var pendingWifiOff = false
    /// 范围文件读不出来（与「从未保存」不同，#971）；设置行据此显示「读不到」而不是「未选相册」。
    @Published private(set) var scopeUnreadable = false
    @Published private(set) var wifiOnly = true
    /// 后台备份默认关（对位 Android `AutoBackupPrefs.autoEnabled = false`，#982）；真值由 `refresh()` 从盘上读。
    @Published private(set) var autoBackup = false
    @Published private(set) var notifyOnFailure = true
    /// #975：系统通知授权的真实状态。开关显示 = 偏好 且 已授权（Android MainActivity 同口径）。
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    private var notificationRequestInFlight = false
    /// onboarding 完成页要不要显示「接下来会问是否允许通知」。
    @Published private(set) var asksNotificationAtOnboarding = false
    /// 当前这张字节上一次前进的时刻（用来判「N 秒没有新数据」）。
    private(set) var transferMark: (orderId: Int64, bytes: Int64, at: Date)?

    init(backend: Backend) {
        self.backend = backend
        let status = backend.pairing.status()
        phase = status == .notPaired ? .onboarding : .main
        refresh()
        refreshExistingAlbums()
        refreshNotificationAuthorization()
        backend.engine.observe { [weak self] in Task { @MainActor in self?.refresh() } }
    }

    /// 回到前台：照常刷新，并重读系统相册（相册可能在系统相册里被删了）。枚举 PhotoKit 有成本，不放进每次引擎回调的 refresh。
    func sceneBecameActive() {
        refresh()
        refreshExistingAlbums()
        refreshNotificationAuthorization() // 用户可能刚从系统设置里改了通知授权回来
    }

    func refreshNotificationAuthorization() {
        Task {
            notificationAuthorization = await backend.engine.notificationAuthorization()
            asksNotificationAtOnboarding = await backend.engine.shouldAskNotificationAtOnboarding()
        }
    }

    var notifyToggleOn: Bool { NotifyToggle.displayValue(preference: notifyOnFailure, authorization: notificationAuthorization) }

    /// 设置页开关。关：只写偏好。开：已授权直接写；没问过就弹系统框、结果写回偏好；已被拒绝（iOS 不会再弹）→ 跳系统设置。
    func setNotifyToggle(_ on: Bool) {
        guard on else { writeNotifyOnFailure(false); return }
        Task {
            let auth = await backend.engine.notificationAuthorization()
            notificationAuthorization = auth
            switch NotifyToggle.turnOnAction(authorization: auth) {
            case .enable:
                writeNotifyOnFailure(true)
            case .requestAuthorization:
                guard !notificationRequestInFlight else { return }
                notificationRequestInFlight = true
                let after = await backend.engine.requestNotificationAuthorization()
                notificationRequestInFlight = false
                notificationAuthorization = after
                writeNotifyOnFailure(after == .authorized)
            case .openSystemSettings:
                backend.engine.openNotificationSettings()
            }
        }
    }

    /// 偏好写盘：成功才更新显示值；失败回到盘上的真实值并给出提示（#971）。
    private func writeNotifyOnFailure(_ on: Bool) {
        do { try backend.engine.setNotifyOnFailure(on); notifyOnFailure = on } catch { settingWriteFailed("notify-on-failure", error) }
    }

    private func settingWriteFailed(_ what: String, _ error: Error) {
        AppLog.log("settings: write failed (\(what)): \(error)")
        refresh() // 开关显示回到盘上的值
        notice = UserNotice(message: L.s("setting_save_failed"))
    }

    private func commandFailed(_ what: String, _ error: Error) {
        AppLog.log("command failed (\(what)): \(error)")
        notice = UserNotice(message: L.s("command_failed"))
    }

    /// onboarding 完成页：该问通知就先问一次（结果同步回开关），再按用户的选择开 / 不开后台备份（Android `thenContinue` 包两个按钮），进首页。
    func finishOnboardingStarted(enableBackgroundBackup: Bool) {
        Task {
            await backend.engine.askNotificationAtOnboarding()
            if enableBackgroundBackup { setAutoBackup(true) }
            refresh()
            refreshNotificationAuthorization()
            phase = .main
        }
    }

    func refreshExistingAlbums() {
        Task {
            existingAlbums = await backend.media.existingAlbumIds()
        }
    }

    func refresh() {
        facts = backend.engine.facts()
        if let v = facts.view, let id = v.currentOrderId {
            if transferMark?.orderId != id || transferMark?.bytes != v.currentBytesSent { transferMark = (id, v.currentBytesSent, Date()) }
        } else { transferMark = nil }
        access = backend.media.access()
        pairing = backend.pairing.status()
        do {
            scope = try backend.media.savedScope()
            scopeUnreadable = false
        } catch {
            if !scopeUnreadable { AppLog.log("backup-scope: unreadable: \(error)") }
            scope = nil
            scopeUnreadable = true
        }
        wifiOnly = backend.engine.wifiOnly()
        autoBackup = backend.engine.autoBackup()
        notifyOnFailure = backend.engine.notifyOnFailure()
        promise = backend.engine.promise().map { n in DiagText.resolve(n.key, vars: n.vars) ?? n.key }
    }


    /// 「取消剩余 N 张」行的 N（Android cancelRemainingRowCount）：只在已暂停 / 等待中、配对没失效、确有剩余时出现。
    var cancelRemainingCount: Int64? {
        guard !pairingLost, facts.state == .paused || facts.state == .waiting else { return nil }
        return facts.remaining.flatMap { $0 > 0 ? $0 : nil }
    }

    /// 用户命令（重试 / 恢复已跳过 / 取消剩余）：出错 → 记日志 + 提示；「状态不允许」不是错误，只刷新（那一行随状态收起，Android 同）。
    private func runCommand(_ what: String, _ op: @escaping () async throws -> Void) {
        guard !commandInFlight else { return }
        commandInFlight = true
        Task {
            do { try await op() } catch { commandFailed(what, error) }
            commandInFlight = false
            refresh()
        }
    }

    /// 点「取消剩余 N 张」那一刻的快照（弹确认框用）；读不出来 → 提示，不弹框。
    func remainingSnapshot() async -> RemainingSnapshot? {
        do { return try await backend.engine.remainingSnapshot() } catch { commandFailed("remaining-snapshot", error); return nil }
    }

    func cancelRemaining(_ snapshot: RemainingSnapshot) {
        runCommand("cancel-remaining") { _ = try await self.backend.engine.cancelRemaining(snapshot) }
    }

    func restoreSkipped() { runCommand("restore-skipped") { try await self.backend.engine.restoreSkipped() } }
    func acknowledgeMissingSource() { backend.engine.acknowledgeMissingSource(); refresh() }

    func setAutoBackup(_ on: Bool) {
        do { try backend.engine.setAutoBackup(on); autoBackup = on } catch { settingWriteFailed("auto-backup", error) }
    }

    /// 「仅 Wi‑Fi」开关：打开直接写；关闭先弹确认（不写盘），确认后才保存（Android MOB-02 §三 / MainActivity `pendingWifiOff`）。
    func setWifiOnly(_ on: Bool) {
        if on { writeWifiOnly(true) } else { pendingWifiOff = true }
    }

    func confirmWifiOff() {
        pendingWifiOff = false
        writeWifiOnly(false)
    }

    func cancelWifiOff() { pendingWifiOff = false }

    private func writeWifiOnly(_ on: Bool) {
        do { try backend.engine.setWifiOnly(on); wifiOnly = on } catch { settingWriteFailed("wifi-only", error) }
    }

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

    /// 「已选相册」个数：已选且当前存在（#983）；从未保存 = nil。
    var selectedAlbumCount: Int? { ScopePolicy.selectedExistingCount(selected: scope, existing: existingAlbums) }

    /// 范围从未保存、保存了空集、或所选相册全被删：一张都不在范围内（Android #541 / #836 同口径）。
    var noAlbums: Bool { (selectedAlbumCount ?? 0) == 0 }
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

    func retry() { runCommand("retry-failed") { try await self.backend.engine.retryFailed() } }

    /// 配对成功后的去向：以前连过这台电脑 → 首页；否则去选相册（Android 同语义）。
    func paired(firstTime: Bool) {
        refresh()
        refreshNotificationAuthorization()
        phase = firstTime ? .chooseAlbums : .main
    }

    func albumsChosen(_ selected: Set<String>, known: Set<String>, firstTime: Bool) {
        Task {
            // 必须在 saveScope 覆盖旧集合之前算差集（Android MOB-20）。
            let previous: Set<String>?
            do { previous = try backend.media.savedScope() } catch {
                AppLog.log("backup-scope: previous scope unreadable, treating every selected album as added: \(error)")
                previous = nil
            }
            let added = ScopePolicy.added(previous: previous, selected: selected)
            do { try await backend.media.saveScope(selected, known: known) } catch {
                // 没存上就不往下走：不进「正在回家」、不叫醒引擎，让用户看到失败并能重试（#971）。
                AppLog.log("backup-scope: save failed: \(error)")
                refresh()
                notice = UserNotice(message: L.s("scope_save_failed"))
                return
            }
            refresh()
            refreshExistingAlbums()
            if firstTime {
                phase = .backupStarted(count: facts.inScopeTotal ?? 0)
            }
            // 只在新增了相册时触发 SCOPE_ADDED；减少或原样保存不触发（Android 同口径，#983）。
            if !added.isEmpty {
                await backend.engine.wake()
                refresh()
            }
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
