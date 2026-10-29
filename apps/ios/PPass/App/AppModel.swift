import Foundation
import PPassCore
import SwiftUI
import UIKit

/// 照片页空状态（#1263，对位 Android TwoTabs 照片 tab）：没选相册 → 引导去选；否则只有一种说法（10-29 文案定稿 C8）。
enum PhotosEmptyHint: Equatable { case chooseAlbums, albums }

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
        /// 首次配对成功：选范围（firstTime）。点「开始备份」直接进首页，没有完成页（#1263）。
        case chooseAlbums
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
    /// 时间档（#1263）；nil = 从未保存过范围。
    @Published private(set) var since: BackupSince?
    /// 系统里当前实际存在的相册（nil = 没有完整授权，读不到）。「已选相册」只数已选且现存的（#983，Android #836）。
    @Published private(set) var existingAlbums: Set<String>?
    /// 照片页「选择相册」：请设置页把选范围页推出来（设置 tab 可能还没建，由它出现时消费）。
    @Published var wantsScopeEditor = false
    /// 「后台 App 刷新」不可用、而用户要后台备份时的全局告示（对位 Android `NoticeHost` 的 BACKUP_INTERRUPTED，UI-12）：
    /// 照片 / 设置两页都看得到，不给「知道了」——事实还在就一直说，退出路径是去系统设置打开，或把「后台备份」关掉。
    @Published private(set) var backgroundNotice: BackgroundNotice?

    struct BackgroundNotice: Equatable {
        let body: String
        /// 用户自己能改（关掉了）才给「去处理」；被屏幕使用时间 / 设备管理限制时用户改不了，不给按钮。
        let canResolve: Bool
    }
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
    /// 首页「开启后台备份」引导卡被关掉过（#1263）。
    @Published private(set) var backgroundCardDismissed = false
    @Published private(set) var notifyOnFailure = true
    /// #975：系统通知授权的真实状态。开关显示 = 偏好 且 已授权（Android MainActivity 同口径）。
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    private var notificationRequestInFlight = false
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

    /// 只重读照片权限档。选范围页读相册时可能刚弹过系统框（`MediaLibrary.albums`），页面要按弹框之后的那一档显示。
    func refreshAccess() { access = backend.media.access() }

    func refreshNotificationAuthorization() {
        Task {
            notificationAuthorization = await backend.engine.notificationAuthorization()
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
        // #1119：配对被清掉（被拒即清理）→ 回欢迎页。界面不在欢迎页（含选相册 / 首次备份）而配对没了，就是这一种。
        let next = Self.phase(phase, whenPairing: pairing)
        if next != phase { AppLog.log("pairing cleared while in \(phase); back to onboarding"); tab = .photos; phase = next }
        do {
            scope = try backend.media.savedScope()
            since = try backend.media.savedSince()
            scopeUnreadable = false
        } catch {
            if !scopeUnreadable { AppLog.log("backup-scope: unreadable: \(error)") }
            scope = nil
            since = nil
            scopeUnreadable = true
        }
        wifiOnly = backend.engine.wifiOnly()
        autoBackup = backend.engine.autoBackup()
        backgroundCardDismissed = backend.engine.backgroundCardDismissed()
        notifyOnFailure = backend.engine.notifyOnFailure()
        backgroundNotice = Self.backgroundNotice(backend.engine.backgroundRefresh(), backgroundRequested: autoBackup)
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

    /// 首页引导卡：后台备份没开、也没被关掉过才显示。
    var showsBackgroundCard: Bool {
        !pairingLost && BackgroundBackupOfferPrefs.shows(autoBackup: autoBackup, dismissed: backgroundCardDismissed)
    }

    /// 引导卡「开启后台备份」。iOS 没有 App 内申请后台运行的系统框（后台 App 刷新只能在系统设置里开），所以只写意图；
    /// 后台 App 刷新被关时由现有的 backgroundNotice 指路（Android 这里弹电池白名单——偏离登记在 tokens.json platforms.ios）。
    func enableBackgroundFromCard() {
        AppLog.log("background-card: enable tapped")
        setAutoBackup(true)
        refresh()
    }

    /// 引导卡「不用了」：写盘失败照样提示，卡片仍在（下次还能关）。
    func dismissBackgroundCard() {
        do { try backend.engine.dismissBackgroundCard(); backgroundCardDismissed = true } catch { settingWriteFailed("background-card", error) }
    }

    /// 「仅 Wi‑Fi」开关：打开直接写；关闭先弹确认（不写盘），确认后才保存（Android MOB-02 §三 / MainActivity `pendingWifiOff`）。
    func setWifiOnly(_ on: Bool) {
        if on { writeWifiOnly(true) } else { pendingWifiOff = true; AppLog.log("wifi-only: off requested, confirm shown") }
    }

    func confirmWifiOff() {
        pendingWifiOff = false
        AppLog.log("wifi-only: off confirmed")
        writeWifiOnly(false)
    }

    func cancelWifiOff() { pendingWifiOff = false; AppLog.log("wifi-only: off cancelled, still on") }

    /// 弹框被系统收起（点了任一按钮之后，或被打断）：只清标志，不写盘、不记日志——按钮各自记。
    func dismissWifiOffPrompt() { pendingWifiOff = false }

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

    /// 只在用户要后台备份时才说（Android：OffByUser 不出告示）；关着后台备份时，后台刷新关不关与用户无关。
    static func backgroundNotice(_ refresh: BackgroundRefreshAvailability, backgroundRequested: Bool) -> BackgroundNotice? {
        guard backgroundRequested else { return nil }
        switch refresh {
        case .available: return nil
        case .denied: return BackgroundNotice(body: L.s("background_refresh_off_notice"), canResolve: true)
        case .restricted: return BackgroundNotice(body: L.s("background_refresh_restricted_notice"), canResolve: false)
        }
    }

    /// 「去处理」：跳到系统设置里 P-Pass 的页面（「后台 App 刷新」开关就在那一页）。
    @MainActor func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

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
    /// 照片页空库时说哪一种（#1263）：没选相册 → 引导去选；否则 →「还没有备份好的照片」。
    var photosEmptyHint: PhotosEmptyHint { noAlbums ? .chooseAlbums : .albums }

    /// 照片页「选择相册」：切到设置 tab 并直达选范围页。
    func openScopeEditor() {
        tab = .settings
        wantsScopeEditor = true
    }

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
    /// settingSaveFailed：换新电脑清旧的后台备份意图没写下来（#1039，对位 Android）——不拦配对，照常往下走，提示用户；
    /// 首次选完范围时再写一次「关」（#1263 起没有完成页）。
    func paired(firstTime: Bool, settingSaveFailed: Bool) {
        if settingSaveFailed {
            AppLog.log("settings: write failed (auto-backup new desktop, ask again)")
            notice = UserNotice(message: L.s("setting_save_failed"))
        }
        refresh()
        refreshNotificationAuthorization()
        // 系统照片权限框由选范围页读相册列表时弹出（`MediaLibrary.albums`），前面不加说明屏（#1259 10-29 改决定）：
        // 说明写在系统框的用途说明 NSPhotoLibraryUsageDescription 里。
        phase = firstTime ? .chooseAlbums : .main
    }

    /// 选范围页点「开始备份」（首次）/「保存」（编辑）。范围 = 相册 + 时间档（#1263）。
    /// 首次：保存范围 → 落盘「连过这台电脑」→ 写一次后台意图（关）→ 唤醒引擎 → 直接进首页，没有完成页。
    func albumsChosen(_ selected: Set<String>, known: Set<String>, wantsAll: Bool, firstTime: Bool) {
        Task {
            // 必须在 saveScope 覆盖旧集合之前算差集（Android MOB-20）。
            var previous: Set<String>?
            var previousSince: BackupSince?
            do { previous = try backend.media.savedScope(); previousSince = try backend.media.savedSince() } catch {
                AppLog.log("backup-scope: previous scope unreadable, treating every selected album as added: \(error)")
                previous = nil
                previousSince = nil
            }
            let since = ScopePolicy.sinceForSave(previous: previousSince, wantsAll: wantsAll, now: Date())
            let added = ScopePolicy.added(previous: previous, selected: selected)
            let widened = ScopePolicy.widened(previous: previousSince, next: since)
            do { try await backend.media.saveScope(selected, known: known, since: since) } catch {
                // 没存上就不往下走：不进首页、不叫醒引擎，让用户看到失败并能重试（#971）。
                AppLog.log("backup-scope: save failed: \(error)")
                refresh()
                notice = UserNotice(message: L.s("scope_save_failed"))
                return
            }
            AppLog.log("backup-scope: saved albums=\(selected.count) since=\(since.isAll ? "all" : "today") added=\(added.count) widened=\(widened)")
            if firstTime { finishFirstScope() }
            refresh()
            refreshExistingAlbums()
            // 新增相册或时间档放宽（从今天起 → 全部）才触发 SCOPE_ADDED 补扫；缩小或原样保存不触发（Android 同口径，#983 / #1263）。
            if !added.isEmpty || widened {
                await backend.engine.wake()
                refresh()
            }
        }
    }

    /// 首次选完范围：记「连过这台电脑」；后台备份按「关」写一次（#1039，对位 Android `onEnterWithoutBackgroundBackup`：
    /// 配对时清旧意图那一步若没写下来，这里补上，否则旧电脑留下的意图会被带到新电脑上）。写失败都提示，照常进首页。
    private func finishFirstScope() {
        AppLog.log("onboarding: first scope saved, entering home")
        // 记不下来不挡进首页：后果只是下次重连同一台仍走一遍首次设置（偏安全的一侧），但要提示，不静默。
        do { try backend.engine.finishOnboarding() } catch { settingWriteFailed("onboarded", error) }
        setAutoBackup(false)
        phase = .main
    }

    /// 主动断开：成功后回到欢迎页，可以重新扫码。
    func disconnect() async {
        await backend.pairing.disconnect()
        refresh()
        tab = .photos
        phase = .onboarding
    }

    /// 配对没了（`.notPaired`）而界面还在配对之后的页面 → 回欢迎页；其余原样。
    nonisolated static func phase(_ phase: Phase, whenPairing pairing: PairingStatus) -> Phase {
        guard pairing == .notPaired, phase != .onboarding else { return phase }
        return .onboarding
    }

    /// 配对失效卡的「重新连接」：先按断开清单清本地（不通知电脑，它本就不认这台手机），再回欢迎页重新扫码（#1119）。
    func startOver() {
        Task {
            await backend.pairing.clearLocal()
            refresh()
            tab = .photos
            phase = .onboarding
        }
    }
}
