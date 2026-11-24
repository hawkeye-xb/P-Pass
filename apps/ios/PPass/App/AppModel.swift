import AVFoundation
import Foundation
import PPassCore
import SwiftUI
import UIKit

enum PhotosGuide: String, Equatable {
    case enableScope = "scope"
    case enableBackground = "background"
    case none

    var logName: String { rawValue }
}

struct GuideFacts: Equatable {
    var scopeOn: Bool
    var firstUploaded: Bool
    var backgroundOn: Bool
    var finished: Bool
    var firstChoicePending: Bool = true
}

struct UserNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case onboarding
        case decision
        case chooseAlbums
        case main
    }

    nonisolated static func launchPhase(_ pairing: PairingStatus, onboarded: Bool) -> Phase {
        switch pairing {
        case .notPaired: return .onboarding
        case .lost: return .main
        case .paired: return onboarded ? .main : .decision
        }
    }

    enum Tab: Hashable { case photos, settings }

    let backend: Backend
    @Published var phase: Phase { didSet { if phase != oldValue { decisionBusy = false } } }
    @Published private(set) var decisionBusy = false
    @Published var tab: Tab = .photos
    @Published private(set) var facts = FlowFacts()
    @Published private(set) var access: MediaAccess = .full
    @Published private(set) var pickedBatch: PickedBatchSummary?
    @Published private(set) var autoRule = false
    @Published private(set) var ruleNote: String?
    // 系统选图器下滑或取消关闭时不触发完成回调，需在 sheet 收起时解锁决定页按钮
    @Published var pickerRequested = false {
        didSet { if oldValue, !pickerRequested, phase == .decision { decisionBusy = false } }
    }
    @Published var filePickerRequested = false {
        didSet { if oldValue, !filePickerRequested, phase == .decision { decisionBusy = false } }
    }
    @Published private(set) var pairing: PairingStatus = .notPaired
    @Published private(set) var scope: Set<String>?
    @Published private(set) var since: BackupSince?
    @Published private(set) var existingAlbums: Set<String>?
    private var knownScopeIds: Set<String> = []
    @Published var wantsScopeEditor = false
    @Published private(set) var backgroundNotice: BackgroundNotice?

    struct BackgroundNotice: Equatable {
        let body: String
        let canResolve: Bool
    }
    @Published var commandInFlight = false
    @Published var notice: UserNotice?
    @Published var showPairingRemovedNotice = false
    @Published var pendingWifiOff = false
    @Published private(set) var scopeUnreadable = false
    @Published private(set) var wifiOnly = true
    @Published private(set) var autoBackup = false
    @Published private(set) var backgroundCardDismissed = false
    @Published private(set) var backgroundRefresh: BackgroundRefreshAvailability = .available
    @Published private(set) var notifyOnFailure = true
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    private var notificationRequestInFlight = false
    private(set) var transferMark: (orderId: Int64, bytes: Int64, at: Date)?
    @Published private(set) var folderCount = 0
    @Published private var liveState = TimelineLiveState()
    private var liveToken: UUID?

    var settingsOpener: @MainActor () -> Void = {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var cameraAuthorized: () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    @Published var resumeToScan = false

    init(backend: Backend) {
        self.backend = backend
        let status = backend.pairing.status()
        phase = Self.launchPhase(status, onboarded: status != .notPaired && backend.engine.onboardedCurrent())
        refresh()
        // iOS 修改系统照片权限会终止进程，回到 App 时可能是冷启动
        resumeAutoRuleAfterSettings()
        refreshExistingAlbums()
        refreshNotificationAuthorization()
        backend.engine.observe { [weak self] in Task { @MainActor in self?.refresh() } }
        liveToken = backend.live.observe { [weak self] event in
            guard case .state(let s) = event else { return }
            self?.liveState = s
        }
    }

    deinit {
        guard let token = liveToken else { return }
        let feed = backend.live
        Task { @MainActor in feed.remove(token) }
    }

    func sceneBecameActive() {
        refresh()
        resumeAutoRuleAfterSettings()
        refreshExistingAlbums()
        refreshNotificationAuthorization()
    }

    func refreshAccess() { access = backend.media.access() }

    func refreshNotificationAuthorization() {
        Task {
            notificationAuthorization = await backend.engine.notificationAuthorization()
        }
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
        let accessBefore = access
        access = backend.media.access()
        if access != accessBefore { AppLog.log("photo access now \(access) (was \(accessBefore))") }
        pairing = backend.pairing.status()
        if backend.pairingRemovedNotice.pending() {
            if pairing == .notPaired { showPairingRemovedNotice = true }
            else { backend.pairingRemovedNotice.dismiss() }
        }
        let next = Self.phase(phase, whenPairing: pairing)
        if next != phase { AppLog.log("pairing cleared while in \(phase); back to onboarding"); tab = .photos; phase = next }
        rereadSavedScope()
        wifiOnly = backend.engine.wifiOnly()
        autoBackup = backend.engine.autoBackup()
        backgroundCardDismissed = backend.engine.backgroundCardDismissed()
        notifyOnFailure = backend.engine.notifyOnFailure()
        backgroundRefresh = backend.engine.backgroundRefresh()
        backgroundNotice = Self.backgroundNotice(backgroundRefresh, backgroundRequested: autoBackup)
        folderCount = backend.engine.folderSourceCount()
    }

    private func rereadSavedScope() {
        do {
            scope = try backend.media.savedScope()
            since = try backend.media.savedSince()
            knownScopeIds = backend.media.knownAlbums()
            scopeUnreadable = false
        } catch {
            if !scopeUnreadable { AppLog.log("backup-scope: unreadable: \(error)") }
            scope = nil
            since = nil
            scopeUnreadable = true
        }
    }

    func refreshFolderCount() {
        folderCount = backend.engine.folderSourceCount()
        rereadSavedScope()
    }

    private func settingWriteFailed(_ what: String, _ error: Error) {
        AppLog.log("settings: write failed (\(what)): \(error)")
        refresh()
        notice = UserNotice(message: L.s("setting_save_failed"))
    }

    private func commandFailed(_ what: String, _ error: Error) {
        AppLog.log("command failed (\(what)): \(error)")
        notice = UserNotice(message: L.s("command_failed"))
    }

    private func runCommand(_ what: String, _ op: @escaping () async throws -> Void) {
        guard !commandInFlight else { return }
        commandInFlight = true
        Task {
            do { try await op() } catch { commandFailed(what, error) }
            commandInFlight = false
            refresh()
        }
    }
}

// MARK: - 连接与首页投影状态

extension AppModel {
    private var pairingLost: Bool { if case .lost = pairing { return true } else { return false } }

    var daysSinceLastReachable: Int? {
        let t = facts.lastReachableAt
        guard t > 0 else { return nil }
        return Int((Int64(Date().timeIntervalSince1970 * 1000) - t) / 86_400_000)
    }

    var pairedAtMs: Int64? { backend.pairing.pairedAtMs() }

    var connection: ConnectionState {
        connectionStateOf(
            pairingLost: pairingLost,
            state: liveState,
            daysUnreachable: daysSinceLastReachable
        )
    }

    var settingsAlert: Bool {
        HomeProjection.settingsAlert(connection: connection, hasBackgroundNotice: backgroundNotice != nil)
    }

    var desktopName: String? {
        switch pairing {
        case .paired(let n), .lost(let n): return n
        case .notPaired: return nil
        }
    }

    var cancelRemainingCount: Int64? {
        guard !connection.needsRepair, facts.state == .paused || facts.state == .waiting else { return nil }
        return facts.remaining.flatMap { $0 > 0 ? $0 : nil }
    }

    var selectedAlbumCount: Int? {
        let albumScope = scope?.filter { !$0.hasPrefix("folder:") }
        return ScopePolicy.selectedExistingCount(selected: albumScope, existing: existingAlbums)
    }

    var selectedFolderCount: Int {
        let folderIds = scope?.filter { $0.hasPrefix("folder:") } ?? []
        if !folderIds.isEmpty { return folderIds.count }
        let unified = knownScopeIds.union(scope ?? []).contains { $0.hasPrefix("folder:") }
        return unified ? 0 : folderCount
    }

    var noAlbums: Bool {
        !ScopePolicy.hasUsableScope(selected: scope, known: knownScopeIds, existingAlbums: existingAlbums, folderCount: folderCount)
    }

    var sourceAvailability: SourceAvailability {
        SourceAvailability(autoRule: autoRule, photoAccess: access,
                           hasUsableFolder: SourceAvailability.hasUsableFolder(selected: scope, known: knownScopeIds, folderCount: folderCount),
                           hasSelectedAlbum: (selectedAlbumCount ?? 0) > 0)
    }

    var ruleHint: String? {
        if let ruleNote { return ruleNote }
        guard autoRule else { return nil }
        switch access {
        case .full: return nil
        case .partial: return sourceAvailability.needsFullPhotoAccessSettings ? L.s("auto_backup_rule_partial_hint") : nil
        case .none: return sourceAvailability.showsDeniedPhotoHint ? L.s("auto_backup_rule_none_hint") : nil
        }
    }

    var autoRuleBlocked: Bool { sourceAvailability.showsGlobalPhotoBlock }

    var backupAvailability: BackupAvailability {
        BackupAvailability(hasUsableSource: sourceAvailability.hasUsableSource,
                           isTransferring: uiState.isRunning)
    }

    nonisolated static func blockedHeroOffersSettings(autoRule: Bool, access: MediaAccess, hasUsableFolder: Bool = false) -> Bool {
        autoRule && access != .full && !hasUsableFolder
    }
    var blockedHeroOffersSettings: Bool { sourceAvailability.showsGlobalPhotoBlock }

    var showsMixedAlbumIncomplete: Bool { sourceAvailability.mixedAlbumIncomplete }

    var uiState: BackupUiState { HomeProjection.backupUiState(facts, noAlbums: noAlbums) }
    var triplet: BackupTriplet? { HomeProjection.triplet(facts, scopeSaved: scope != nil) }

    static func backgroundNotice(_ refresh: BackgroundRefreshAvailability, backgroundRequested: Bool) -> BackgroundNotice? {
        guard backgroundRequested else { return nil }
        switch refresh {
        case .available: return nil
        case .denied: return BackgroundNotice(body: L.s("background_refresh_off_notice"), canResolve: true)
        case .restricted: return BackgroundNotice(body: L.s("background_refresh_restricted_notice"), canResolve: false)
        }
    }
}

// MARK: - 引导位与范围决策

extension AppModel {
    nonisolated static func photosGuideOf(_ f: GuideFacts) -> PhotosGuide {
        if f.finished { return .none }
        if !f.scopeOn { return f.firstChoicePending ? .enableScope : .none }
        if f.firstUploaded && !f.backgroundOn { return .enableBackground }
        return .none
    }

    nonisolated static func scopeEmptyHintShown(_ f: GuideFacts, inScope: Int64?) -> Bool { f.scopeOn && inScope == 0 }

    var guideFacts: GuideFacts {
        GuideFacts(scopeOn: autoRule && (scopeUnreadable || !noAlbums), firstUploaded: facts.lastSuccessAt > 0,
                   backgroundOn: Self.backgroundBackupOn(intent: autoBackup, refresh: backgroundRefresh), finished: backgroundCardDismissed,
                   firstChoicePending: !scopeUnreadable && scope == nil && folderCount == 0)
    }

    nonisolated static func backgroundBackupOn(intent: Bool, refresh: BackgroundRefreshAvailability) -> Bool {
        switch refresh {
        case .available: return intent
        case .denied: return false
        case .restricted: return true
        }
    }

    var scopeGuideActionKey: String {
        if !autoRule && sourceAvailability.needsFullPhotoAccessSettings { return "auto_backup_blocked_action" }
        return "photos_guide_enable"
    }

    var backgroundGuideActionKey: String { backgroundRefresh == .available ? "photos_guide_enable" : "background_refresh_notice_action" }

    var photosGuide: PhotosGuide { Self.photosGuideOf(guideFacts) }

    var scopeEmptyHint: String? {
        guard Self.scopeEmptyHintShown(guideFacts, inScope: triplet?.n) else { return nil }
        let name = desktopName ?? L.s("storage_device_default")
        if case .since(let ms)? = since {
            return L.f("photos_scope_empty_since", SettingsScreen.scopeDate(Date(timeIntervalSince1970: Double(ms) / 1000)), name)
        }
        return L.f("photos_scope_empty_all", name)
    }

    func guideAction(_ guide: PhotosGuide) {
        switch guide {
        case .enableScope:
            if autoRule { openScopeEditor() } else { setAutoRule(true) }
        case .enableBackground:
            if !autoBackup { setAutoBackup(true) }
            if backgroundRefresh != .available { openAppSettings() }
        case .none:
            break
        }
    }

    func dismissGuide() {
        do {
            try backend.engine.dismissBackgroundCard()
            backgroundCardDismissed = true
            AppLog.log("photos-guide: dismissed")
        } catch { settingWriteFailed("onboarding-guide", error) }
    }

    func openScopeEditor() {
        tab = .settings
        wantsScopeEditor = true
    }
}

// MARK: - 用户操作与引导流程

extension AppModel {
    var notifyToggleOn: Bool { NotifyToggle.displayValue(preference: notifyOnFailure, authorization: notificationAuthorization) }

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

    private func writeNotifyOnFailure(_ on: Bool) {
        do { try backend.engine.setNotifyOnFailure(on); notifyOnFailure = on } catch { settingWriteFailed("notify-on-failure", error) }
    }

    @MainActor func openSettingsFromBlockedHero() {
        AppLog.log("auto-rule: blocked (photo access=\(access)), opening app settings")
        openAppSettings()
    }

    @MainActor func adjustScopeFromIncompleteAlbum() {
        AppLog.log("auto-rule: mixed scope, photo access=\(access), opening scope editor")
        openScopeEditor()
    }

    func setAutoRule(_ on: Bool) {
        ruleNote = nil
        guard on else {
            do { try backend.engine.setAutoRule(false); autoRule = false } catch { settingWriteFailed("auto-rule", error) }
            return
        }
        if backend.media.access() == .partial && !sourceAvailability.hasUsableFolder {
            do { try backend.engine.setPendingFullPhotoAccess(true) } catch { AppLog.log("auto-rule: pending mark write failed: \(error)") }
            AppLog.log("auto-rule: partial photo access, opening system settings for full access")
            openAppSettings()
            return
        }
        Task { await enableAutoRuleWithoutPhotoGate() }
    }

    private func enableAutoRuleWithoutPhotoGate() async {
        access = backend.media.access()
        do { try backend.engine.setAutoRule(true); autoRule = true } catch { settingWriteFailed("auto-rule", error); return }
        refresh()
        if access == .full { refreshExistingAlbums() }
        if noAlbums { openScopeEditor() } else { await backend.engine.wake() }
    }

    private func applyAutoRuleAccess(_ granted: MediaAccess) async {
        access = granted
        switch granted {
        case .full:
            do { try backend.engine.setAutoRule(true); autoRule = true } catch { settingWriteFailed("auto-rule", error); return }
            refresh()
            refreshExistingAlbums()
            if noAlbums { openScopeEditor() } else { await backend.engine.wake() }
        case .partial:
            let n = await backend.engine.sendAllowedPhotos()
            ruleNote = L.s("auto_backup_rule_partial_hint")
            AppLog.log("auto-rule: partial photo access, sent allowed photos n=\(n), rule stays off")
        case .none:
            ruleNote = L.s("auto_backup_rule_denied_hint")
        }
        refresh()
    }

    func resumeAutoRuleAfterSettings() {
        guard backend.engine.pendingFullPhotoAccess() else { return }
        do { try backend.engine.setPendingFullPhotoAccess(false) } catch { AppLog.log("auto-rule: pending mark clear failed: \(error)"); return }
        guard phase == .main else { AppLog.log("auto-rule: back from settings outside main (\(phase)); dropped"); return }
        let now = backend.media.access()
        AppLog.log("auto-rule: back from settings, photo access=\(now)")
        Task { await applyAutoRuleAccess(now) }
    }

    func pickedChosen(_ items: [(fileName: String, mimeType: String, payload: PickedPayload)]) {
        guard !items.isEmpty else {
            if phase == .decision { AppLog.log("onboarding: pick cancelled, staying on decision"); decisionBusy = false }
            return
        }
        AppLog.log("picked: \(items.count) chosen")
        if phase == .decision { decisionBusy = true }
        Task {
            let added = await backend.engine.addPicked(items)
            if added > 0 { AppLog.log("picked: \(added) registered") }
            refresh()
            guard phase == .decision else { return }
            guard added > 0 else {
                AppLog.log("onboarding: pick registered nothing, staying on decision")
                decisionBusy = false
                return
            }
            markDecided(via: "pick")
            phase = .main
        }
    }

    func decisionShown() {
        AppLog.log("onboarding: decision shown")
    }

    func decisionChooseScope() {
        guard phase == .decision, !decisionBusy else { return }
        do {
            try backend.engine.setAutoRule(true)
        } catch {
            settingWriteFailed("auto-rule", error)
            return
        }
        autoRule = true
        AppLog.log("onboarding: auto backup enabled, opening scope")
        phase = .chooseAlbums
    }

    func decisionPickPhotos() {
        guard !decisionBusy else { return }
        decisionBusy = true
        pickerRequested = true
    }

    func decisionPickFiles() {
        guard phase == .decision, !decisionBusy else { return }
        decisionBusy = true
        filePickerRequested = true
    }

    func leaveFirstScope() {
        guard phase == .chooseAlbums else { return }
        phase = .decision
    }

    private func markDecided(via: String) {
        do {
            try backend.engine.finishOnboarding()
            AppLog.log("onboarding: marked onboarded via=\(via)")
        } catch { settingWriteFailed("onboarded", error) }
    }

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

    func setWifiOnly(_ on: Bool) {
        if on { writeWifiOnly(true) } else { pendingWifiOff = true; AppLog.log("wifi-only: off requested, confirm shown") }
    }

    func confirmWifiOff() {
        pendingWifiOff = false
        AppLog.log("wifi-only: off confirmed")
        writeWifiOnly(false)
    }

    func cancelWifiOff() { pendingWifiOff = false; AppLog.log("wifi-only: off cancelled, still on") }

    func dismissWifiOffPrompt() { pendingWifiOff = false }

    private func writeWifiOnly(_ on: Bool) {
        do { try backend.engine.setWifiOnly(on); wifiOnly = on } catch { settingWriteFailed("wifi-only", error) }
    }

    @MainActor func openAppSettings() { settingsOpener() }

    func pauseOrResume() {
        commandInFlight = true
        Task {
            await backend.engine.pauseOrResume()
            commandInFlight = false
            refresh()
        }
    }

    func retry() { runCommand("retry-failed") { try await self.backend.engine.retryFailed() } }

    func paired(firstTime: Bool, settingSaveFailed: Bool) {
        if settingSaveFailed {
            AppLog.log("settings: write failed (auto-backup new desktop, ask again)")
            notice = UserNotice(message: L.s("setting_save_failed"))
        }
        refresh()
        refreshNotificationAuthorization()
        if firstTime {
            setAutoBackup(false)
            setAutoRule(false)
            phase = .decision
        } else {
            phase = .main
        }
    }

    func albumsChosen(_ selected: Set<String>, known: Set<String>, wantsAll: Bool, firstTime: Bool, onSaved: (() -> Void)? = nil) {
        Task {
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
                AppLog.log("backup-scope: save failed: \(error)")
                refresh()
                notice = UserNotice(message: L.s("scope_save_failed"))
                return
            }
            AppLog.log("backup-scope: saved sources=\(selected.count) since=\(since.isAll ? "all" : "today") added=\(added.count) widened=\(widened)")
            if firstTime { finishFirstScope() }
            refresh()
            refreshExistingAlbums()
            onSaved?()
            if !added.isEmpty || widened {
                await backend.engine.wake()
                refresh()
            }
        }
    }

    private func finishFirstScope() {
        AppLog.log("onboarding: first scope saved, entering home")
        markDecided(via: "scope")
        do { try backend.engine.setAutoRule(true); autoRule = true } catch { settingWriteFailed("auto-rule", error) }
        setAutoBackup(false)
        phase = .main
    }

    func disconnect() async {
        await backend.pairing.disconnect()
        refresh()
        tab = .photos
        phase = .onboarding
    }

    nonisolated static func phase(_ phase: Phase, whenPairing pairing: PairingStatus) -> Phase {
        guard pairing == .notPaired, phase != .onboarding else { return phase }
        return .onboarding
    }

    func dismissPairingRemovedNotice() {
        backend.pairingRemovedNotice.dismiss()
        showPairingRemovedNotice = false
    }

    func consumeResumeToScan() { resumeToScan = false }

    func startOver() {
        Task {
            await backend.pairing.clearLocal()
            refresh()
            tab = .photos
            resumeToScan = cameraAuthorized()
            phase = .onboarding
        }
    }
}
