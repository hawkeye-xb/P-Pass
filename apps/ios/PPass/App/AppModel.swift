import Foundation
import PPassCore
import SwiftUI
import UIKit

/// #1324 照片页引导位给哪一张（ADR 结论 6，对位 Android `PhotosGuide`）。决定页之后的引导都是可选的，按当前开关现算，不按「走到第几步」记。
enum PhotosGuide: String, Equatable {
    /// 没开范围备份（「自动备份」关，或开着但一个相册都没选）。原「还没有选择相册」与首次空状态并入这一步。
    case enableScope = "scope"
    /// 范围备份已开、第一张已传成功、后台备份没开。
    case enableBackground = "background"
    case none

    var logName: String { rawValue }
}

/// `AppModel.photosGuideOf` 的输入：都是此刻的真实状态（对位 Android `GuideFacts`）。
struct GuideFacts: Equatable {
    /// 「自动备份」规则开着，且范围里至少有一个相册（读不出来的范围按「有」算，设置行另说「读不到」）。
    var scopeOn: Bool
    /// 成功传过至少一张（账本里最后成功时间不为 0）。
    var firstUploaded: Bool
    /// 用户开了后台备份（意图；系统「后台 App 刷新」没放行另有告示接手）。
    var backgroundOn: Bool
    /// 「onboarding 已走完」：用户点过引导位的 ×。按手机记（`background_backup_offer.json`，断开清单 KEEP），断开、换电脑都不重置。
    var finished: Bool
}

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
        /// #1323 决定页（onboarding 闸门 2026-11-03）：首次 / 新电脑配对后，先决定「备份哪些照片」（范围备份 / 单张备份），做完才进照片页。
        case decision
        /// 决定页选了范围备份、照片权限全部允许：首次选范围（firstTime）。点「开始备份」直接进首页，没有完成页（#1263）；取消回决定页。
        case chooseAlbums
        case main
    }

    /// 冷启动的首屏（#1323 判断 B，对位 Android `launchScreen`）。补记（`OnboardedDesktopsStore.initIfAbsent`）已在
    /// `LiveBackend.init` 做过，这里**只看记录**：这台没有记录（含决定页被杀）→ 决定页。不看范围——选了单张备份的人有记录、
    /// 范围为空，看范围的话每次打开都会被拦一次。完整判据 `isKnownDesktop` 只用在配对成功后的分流（`LivePairing`）。
    /// 配对失效（`.lost`）→ 照片页：只有那里有「重新连接」红卡，决定页没有出路。
    nonisolated static func launchPhase(_ pairing: PairingStatus, onboarded: Bool) -> Phase {
        switch pairing {
        case .notPaired: return .onboarding
        case .lost: return .main
        case .paired: return onboarded ? .main : .decision
        }
    }

    /// 决定页主按钮「选择备份范围」在照片权限框之后去哪（ADR 结论 5，对位 Android `decisionLanding`）：
    /// 全部允许 → 选范围页；拒绝 → 系统选图（单张备份）。
    /// 部分允许：iOS 在权限框里已经弹了系统自己的选照片页，用户在那里选的就是这次的「系统选图」——
    /// 直接登记这些已授权的照片（单张备份），不再弹 App 的选图器让人选第二遍。都不新增第三个出口。
    enum DecisionLanding: Equatable { case chooseScope, registerAllowed, pickPhotos }

    nonisolated static func decisionLanding(_ access: MediaAccess) -> DecisionLanding {
        switch access {
        case .full: return .chooseScope
        case .partial: return .registerAllowed
        case .none: return .pickPhotos
        }
    }

    enum Tab: Hashable { case photos, settings }

    let backend: Backend
    @Published var phase: Phase
    @Published var tab: Tab = .photos
    @Published private(set) var facts = FlowFacts()
    @Published private(set) var access: MediaAccess = .full
    /// #1272 挑几张传：最近一批的进度 / 结果（没挑过 = nil）。
    @Published private(set) var pickedBatch: PickedBatchSummary?
    /// #1272 B：「自动备份」规则开关；开关下一行小字（被拒 / 有限访问传了一次的说明）；系统照片选择器是否要弹出。
    @Published private(set) var autoRule = false
    @Published private(set) var ruleNote: String?
    @Published var pickerRequested = false
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
    /// 当前页的瞬时提示（对位 Android snackbar），任何页面都显示，几秒后自动消失。
    @Published var toast: String?
    /// 部分照片权限下点了开自动备份、被带去系统设置：回到前台时按真实权限接着走。只在内存里，不落盘。
    private(set) var awaitingFullPhotoAccess = false
    /// 「仅 Wi‑Fi」要关：等用户在确认框里点「仍然关闭」才写盘（Android MOB-02 §三：移动网络会消耗流量）。
    @Published var pendingWifiOff = false
    /// 范围文件读不出来（与「从未保存」不同，#971）；设置行据此显示「读不到」而不是「未选相册」。
    @Published private(set) var scopeUnreadable = false
    @Published private(set) var wifiOnly = true
    /// 后台备份默认关（对位 Android `AutoBackupPrefs.autoEnabled = false`，#982）；真值由 `refresh()` 从盘上读。
    @Published private(set) var autoBackup = false
    /// 首页「开启后台备份」引导卡被关掉过（#1263）。
    @Published private(set) var backgroundCardDismissed = false
    /// 系统「后台 App 刷新」此刻的真实状态（#1324：引导位第二步按它现算）。
    @Published private(set) var backgroundRefresh: BackgroundRefreshAvailability = .available
    @Published private(set) var notifyOnFailure = true
    /// #975：系统通知授权的真实状态。开关显示 = 偏好 且 已授权（Android MainActivity 同口径）。
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    private var notificationRequestInFlight = false
    /// 当前这张字节上一次前进的时刻（用来判「N 秒没有新数据」）。
    private(set) var transferMark: (orderId: Int64, bytes: Int64, at: Date)?

    init(backend: Backend) {
        self.backend = backend
        let status = backend.pairing.status()
        phase = Self.launchPhase(status, onboarded: status != .notPaired && backend.engine.onboardedCurrent())
        refresh()
        refreshExistingAlbums()
        refreshNotificationAuthorization()
        backend.engine.observe { [weak self] in Task { @MainActor in self?.refresh() } }
    }

    /// 回到前台：照常刷新，并重读系统相册（相册可能在系统相册里被删了）。枚举 PhotoKit 有成本，不放进每次引擎回调的 refresh。
    func sceneBecameActive() {
        refresh()
        resumeAutoRuleAfterSettings()
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

    /// 开关下一行小字：刚做完的动作的说明优先；其次是规则开着时权限被收回 / 改成部分的状态（#1272 B，唯一保留的权限提示）。
    var ruleHint: String? {
        if let ruleNote { return ruleNote }
        guard autoRule else { return nil }
        switch access {
        case .full: return nil
        case .partial: return L.s("auto_backup_rule_partial_hint")
        case .none: return L.s("auto_backup_rule_none_hint")
        }
    }

    /// 规则开着、但权限被收回 / 改成部分：自动备份已停止（偏好不动，单独显示成这一种状态）。
    var autoRuleBlocked: Bool { autoRule && access != .full }

    /// 「自动备份」开关（设置页与照片页空状态的主按钮共用）。关：只写偏好。开：此刻才申请照片权限——
    /// 全部允许 → 开，并总是进选范围页确认范围（#1323，对位 Android：已有范围也不再直接开始）；
    /// 有限访问 → 开关保持关，把允许的照片按手选链路传一次；不允许 → 保持关 + 一行小字。
    func setAutoRule(_ on: Bool) {
        ruleNote = nil
        guard on else {
            do { try backend.engine.setAutoRule(false); autoRule = false } catch { settingWriteFailed("auto-rule", error) }
            return
        }
        // 已经是「部分照片」：iOS 不会再弹授权框（Android 这一步会再弹一次、可当场改成「全部允许」）。同一意图的 iOS 做法是
        // 带用户去系统设置里本 App 的「照片」项改成「所有照片」；回到前台按真实权限接着走（`sceneBecameActive`）。不预写任何开关。
        if backend.media.access() == .partial {
            awaitingFullPhotoAccess = true
            AppLog.log("auto-rule: partial photo access, opening system settings for full access")
            openAppSettings()
            return
        }
        Task {
            let granted = await backend.media.requestAccess()
            await applyAutoRuleAccess(granted)
        }
    }

    /// 开自动备份时拿到的照片权限档 → 结果（对位 Android 授权回调）：全部 → 开、进选范围页；
    /// 部分 → 开关保持关，把允许的照片传一次，当前页瞬时提示；拒绝 → 保持关 + 一行小字。
    private func applyAutoRuleAccess(_ granted: MediaAccess) async {
        access = granted
        switch granted {
        case .full:
            do { try backend.engine.setAutoRule(true); autoRule = true } catch { settingWriteFailed("auto-rule", error); return }
            refresh()
            refreshExistingAlbums()
            openScopeEditor()
            // 已有范围的用户在选范围页原样「保存」不会触发补扫（没有新增 / 放宽），规则刚打开要叫醒一轮，不然开了也不跑。
            if !noAlbums { await backend.engine.wake() }
        case .partial:
            let n = await backend.engine.sendAllowedPhotos()
            ruleNote = n > 0 ? L.f("auto_backup_rule_limited_sent", n) : L.s("auto_backup_rule_partial_hint")
            toast = ruleNote
            AppLog.log("auto-rule: partial photo access, sent allowed photos n=\(n), rule stays off")
        case .none:
            ruleNote = L.s("auto_backup_rule_denied_hint")
        }
        refresh()
    }

    /// 从系统设置回来：按真实照片权限现算（同 #1324 读后台刷新的口径）。只处理一次。
    private func resumeAutoRuleAfterSettings() {
        guard awaitingFullPhotoAccess else { return }
        awaitingFullPhotoAccess = false
        let now = backend.media.access()
        AppLog.log("auto-rule: back from settings, photo access=\(now)")
        Task { await applyAutoRuleAccess(now) }
    }

    /// #1272：系统选择器选完。照片不复制，只登记句柄；传输由引擎在前台逐张进行。
    /// #1323：在决定页选的（单张备份）——登记成功才算做了决定：落盘「连过这台」、进照片页；取消或一张没登记上 → 留在决定页。
    func pickedChosen(_ items: [(fileName: String, mimeType: String, payload: PickedPayload)]) {
        guard !items.isEmpty else {
            if phase == .decision { AppLog.log("onboarding: pick cancelled, staying on decision") }
            return
        }
        AppLog.log("picked: \(items.count) chosen")
        Task {
            let added = await backend.engine.addPicked(items)
            refresh()
            guard phase == .decision else { return }
            guard added > 0 else { AppLog.log("onboarding: pick registered nothing, staying on decision"); return }
            markDecided(via: "pick")
            phase = .main
        }
    }

    // MARK: #1323 决定页

    /// 决定页出现（含冷启动直接落在决定页）：和 Android 同一句日志，E3 据此判定。
    func decisionShown() {
        AppLog.log("onboarding: decision shown")
    }

    /// 决定页主按钮「选择备份范围」：申请照片权限（读写、全部照片），按结果分流（`decisionLanding`）。
    func decisionChooseScope() {
        Task {
            let granted = await backend.media.requestAccess()
            access = granted
            AppLog.log("onboarding: photo access after prompt=\(granted)")
            guard phase == .decision else { return }
            switch Self.decisionLanding(granted) {
            case .chooseScope: phase = .chooseAlbums
            case .registerAllowed: await registerAllowedOnDecision()
            case .pickPhotos: pickerRequested = true
            }
        }
    }

    /// 部分允许：登记系统已授权的照片（同 `pickedChosen` 的单张备份口径）。登记上才算做了决定：落盘、进照片页；
    /// 一张都没登记上（授权集为空）→ 留在决定页。
    private func registerAllowedOnDecision() async {
        let n = await backend.engine.sendAllowedPhotos()
        refresh()
        guard phase == .decision else { return }
        guard n > 0 else { AppLog.log("onboarding: partial access registered nothing, staying on decision"); return }
        AppLog.log("onboarding: partial access registered \(n) allowed photos")
        markDecided(via: "pick")
        phase = .main
    }

    /// 决定页次入口「先挑几张试试」：直接系统选图（不要照片权限）。
    func decisionPickPhotos() { pickerRequested = true }

    /// 首次选范围页「返回」：还没做决定，回决定页（对位 Android `systemBackTarget` 的 Buckets(firstTime) → Decision）。
    func leaveFirstScope() {
        guard phase == .chooseAlbums else { return }
        phase = .decision
    }

    /// 「连过这台电脑」落盘（ADR 结论 2）：只在决定页做出选择那一刻——范围保存成功（via=scope）或单张选完登记成功（via=pick）。
    /// 记不下来不挡进照片页、提示（#1039 同口径）：后果只是下次打开仍回决定页（偏安全的一侧）。
    private func markDecided(via: String) {
        do {
            try backend.engine.finishOnboarding()
            AppLog.log("onboarding: marked onboarded via=\(via)")
        } catch { settingWriteFailed("onboarded", error) }
    }

    func refreshExistingAlbums() {
        Task {
            existingAlbums = await backend.media.existingAlbumIds()
        }
    }

    func refresh() {
        facts = backend.engine.facts()
        pickedBatch = backend.engine.pickedSummary()
        autoRule = backend.engine.autoRule()
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
        // 系统「后台 App 刷新」的真实状态：回到前台（sceneBecameActive → refresh）时重读，用户在系统设置里改了回来就生效。
        backgroundRefresh = backend.engine.backgroundRefresh()
        backgroundNotice = Self.backgroundNotice(backgroundRefresh, backgroundRequested: autoBackup)
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
    @MainActor func openAppSettings() { settingsOpener() }

    /// 真正跳系统设置的动作；测试换成计数，不去开真的设置。
    var settingsOpener: @MainActor () -> Void = {
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

    // MARK: #1324 照片页引导位与范围内暂无照片的现状（ADR 结论 6、7，对位 Android #1322）

    /// 没开范围备份 → 引导开启；范围备份已开、第一张已传、后台没开 → 引导开后台；都开了 → 结束。点过 × 整条结束。
    /// 起点按现状：决定页直接选了范围备份的，不会出现「开启范围备份」。
    nonisolated static func photosGuideOf(_ f: GuideFacts) -> PhotosGuide {
        if f.finished { return .none }
        if !f.scopeOn { return .enableScope }
        if f.firstUploaded && !f.backgroundOn { return .enableBackground }
        return .none
    }

    /// 范围备份开着、范围里一张照片都还没有 → 过滤条下方一行现状。状态提示不是引导：不看 `finished`；有了第一张就不说；
    /// `inScope` 为 nil（还没数出来）不说。
    nonisolated static func scopeEmptyHintShown(_ f: GuideFacts, inScope: Int64?) -> Bool { f.scopeOn && inScope == 0 }

    var guideFacts: GuideFacts {
        GuideFacts(scopeOn: autoRule && (scopeUnreadable || !noAlbums), firstUploaded: facts.lastSuccessAt > 0,
                   backgroundOn: Self.backgroundBackupOn(intent: autoBackup, refresh: backgroundRefresh), finished: backgroundCardDismissed)
    }

    /// iOS 后台备份真正生效 = App 里「后台备份」开着（这是 App 自己的开关，系统里没有对应项，只能读它的存值）
    /// **且**系统「后台 App 刷新」放行（读系统真实状态）。被限制（屏幕使用时间 / 设备管理）用户自己改不了，引导位不劝，
    /// 交给设置页告示说现状——按「已开」处理，不出第二步卡。
    nonisolated static func backgroundBackupOn(intent: Bool, refresh: BackgroundRefreshAvailability) -> Bool {
        switch refresh {
        case .available: return intent
        case .denied: return false
        case .restricted: return true
        }
    }

    /// 第二步卡的按钮名：系统「后台 App 刷新」没开 →「去设置」；系统已放行、只差 App 里的开关 →「开启」。
    /// 第一步卡的按钮名：已是「部分照片」、规则没开 → 点了会去系统设置改权限，按钮说「去设置」（复用现有词）；否则「开启」。
    var scopeGuideActionKey: String { !autoRule && access == .partial ? "background_refresh_notice_action" : "photos_guide_enable" }

    var backgroundGuideActionKey: String { backgroundRefresh == .available ? "photos_guide_enable" : "background_refresh_notice_action" }

    var photosGuide: PhotosGuide { Self.photosGuideOf(guideFacts) }

    /// 范围内暂无照片的一行现状；nil = 不显示。「从今天起」一律写日期（同设置行）。
    var scopeEmptyHint: String? {
        guard Self.scopeEmptyHintShown(guideFacts, inScope: triplet?.n) else { return nil }
        let name = desktopName ?? L.s("storage_device_default")
        if case .since(let ms)? = since {
            return L.f("photos_scope_empty_since", SettingsScreen.scopeDate(Date(timeIntervalSince1970: Double(ms) / 1000)), name)
        }
        return L.f("photos_scope_empty_all", name)
    }

    /// 引导位的按钮。第一步：规则开着（只是没选相册）→ 直达选范围页，关着 → 走开启链路（权限 → 选范围页）。
    /// 第二步（iOS）：见 `backgroundBackupOn`——缺哪项补哪项。
    func guideAction(_ guide: PhotosGuide) {
        switch guide {
        case .enableScope:
            if autoRule { openScopeEditor() } else { setAutoRule(true) }
        case .enableBackground:
            // App 里的「后台备份」开关系统读不到、只能由 App 写（唯一「先写意图」的一项）；系统「后台 App 刷新」不预先写任何东西，
            // 只把用户带到本 App 的系统设置页，回到前台时按真实状态重算卡片。
            if !autoBackup { setAutoBackup(true) }
            if backgroundRefresh != .available { openAppSettings() }
        case .none:
            break
        }
    }

    /// 引导位的 ×：「onboarding 已走完」落盘（按手机记）。写不下来卡片留着、提示（#1039 同口径）。
    func dismissGuide() {
        do {
            try backend.engine.dismissBackgroundCard()
            backgroundCardDismissed = true
            AppLog.log("photos-guide: dismissed")
        } catch { settingWriteFailed("onboarding-guide", error) }
    }

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

    /// 配对成功后的去向（#1323，ADR 结论 3、4）：连过这台电脑（有记录 && 这台范围非空，`LivePairing` 判）→ 首页，保留原配置；
    /// 首次 / 新电脑 → 决定页。配对成功本身**不**落盘「连过」，落盘在决定页的选择回调（`markDecided`）。
    /// settingSaveFailed：换新电脑清旧的后台备份意图没写下来（#1039，对位 Android）——不拦配对，照常往下走，提示用户；
    /// 首次选完范围时再写一次「关」（#1263 起没有完成页）。
    func paired(firstTime: Bool, settingSaveFailed: Bool) {
        if settingSaveFailed {
            AppLog.log("settings: write failed (auto-backup new desktop, ask again)")
            notice = UserNotice(message: L.s("setting_save_failed"))
        }
        refresh()
        refreshNotificationAuthorization()
        // #1272 B：配对这一步不申请照片权限；决定页主按钮才申请。
        // 新电脑：规则与后台备份都按「关」写一次（旧电脑留下的意图不带到新电脑）。
        if firstTime {
            setAutoBackup(false)
            setAutoRule(false)
            phase = .decision
        } else {
            phase = .main
        }
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

    /// 首次选完范围（决定页选了范围备份）：记「连过这台电脑」（via=scope）；「自动备份」规则随之打开（#1323，对位 Android
    /// `rulePrefs.set(true)`——直接写，不走 `setAutoRule(true)`：那条会再申请一次权限、再推一次选范围页）；
    /// 后台备份按「关」写一次（#1039，对位 Android `onEnterWithoutBackgroundBackup`：配对时清旧意图那一步若没写下来，这里补上，
    /// 否则旧电脑留下的意图会被带到新电脑上）。写失败都提示，照常进首页。
    private func finishFirstScope() {
        AppLog.log("onboarding: first scope saved, entering home")
        markDecided(via: "scope")
        do { try backend.engine.setAutoRule(true); autoRule = true } catch { settingWriteFailed("auto-rule", error) }
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
