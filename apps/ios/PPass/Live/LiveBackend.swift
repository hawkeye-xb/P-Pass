import Foundation
import Network
import PPassBackgroundTasks
import PPassCore
import PPassMedia
import PPassTransport
import UIKit

/// 真实现的总装（#925）：存储根 → 身份 → 控制面 → 配对 → 相册 → Flow 引擎（+ 前台追赶 / 后台尽力而为 #340）。
/// 端口的实现都在 Live/ 里，引擎与账本在 PPassCore，PhotoKit 在 PPassMedia，字节与 BLAKE3 在传输 FFI。
final class LiveBackend: @unchecked Sendable {
    static let appGroup = "group.com.hawkeyexb.ppass"

    let root: StorageRoot
    let logger: CoreLogger = OSLogger()
    let plane: ControlPlane
    let pairingStore: PairingStore
    let onboarded: OnboardedDesktopsStore
    let media: LiveMediaLibrary
    let window = ExecutionWindow()
    let scheduler: PlannedWakeScheduler
    let engine: FlowEngine
    let catchup: ForegroundCatchup
    let provider: NativeProvider
    let orders: SQLiteOrderStore
    let control: FlowControlStore
    let settings: BackupSettings
    let autoPrefs: AutoBackupPrefs
    let notifyPrefs: NotifyOnFailurePrefs
    let notificationAsk: OnboardingNotificationAsk
    let pairingLoss = PairingLoss()
    let sentinel: SentinelStore
    let heartbeat: ForegroundHeartbeat
    let network = NetworkState()
    let pendingUnpair: PendingUnpairStore
    let unpairFlusher: PendingUnpairFlusher
    let engineModel: LiveEngineModel
    /// 前台相册变化监听（#978，对位 Android BackupUiStateHolder 的 MediaStore ContentObserver）。
    let mediaWatcher: MediaChangeWatcher

    init() throws {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let logger = self.logger
        root = try StorageRoot.resolve(appGroupContainer: fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup),
                                       groupIdentifier: Self.appGroup, appPrivateDirectory: appSupport, logger: logger)
        let dir = root.url
        plane = ControlPlane(secretKey: try IdentityKey.loadOrCreate(in: dir))
        pairingStore = PairingStore(root: dir)
        onboarded = OnboardedDesktopsStore(directory: dir, logger: logger)
        let pairingStore = self.pairingStore
        pendingUnpair = PendingUnpairStore(directory: dir, logger: logger)
        let planeForUnpair = plane
        unpairFlusher = PendingUnpairFlusher(store: pendingUnpair, now: { Int64(Date().timeIntervalSince1970 * 1000) }, logger: logger) {
            PeerCtrlTransport(plane: planeForUnpair, peerToken: $0)
        }
        media = LiveMediaLibrary { BackupScopeStore(directory: dir, daemonNodeId: pairingStore.load()?.daemonNodeId, logger: logger) }
        provider = try NativeProvider(root: dir)
        try? provider.ffi.setAllowedPeer(nodeId: pairingStore.load()?.daemonNodeId)
        orders = try SQLiteOrderStore(directory: dir, logger: logger)
        // 收件箱（#958）：与账本同一个文件、独立的表和连接。必须在账本之后打开——账本发现文件损坏会删掉整个文件重建。
        let inbox = try Inbox(path: orders.path, history: PhotoKitChangeHistory(), log: { logger.log($0) })
        control = FlowControlStore(directory: dir, logger: logger)
        settings = BackupSettings(directory: dir, logger: logger)
        autoPrefs = AutoBackupPrefs(directory: dir, logger: logger)
        notifyPrefs = NotifyOnFailurePrefs(directory: dir, logger: logger)
        // #975：必须在任何 markOnboarded 之前定老用户（新装用户此刻没有配对、没走过 onboarding，写下 asked=false）。
        notificationAsk = OnboardingNotificationAsk(directory: dir, logger: logger)
        notificationAsk.initIfAbsent(existingUser: pairingStore.load() != nil || onboarded.anyOnboarded())
        // 全新安装默认开（此前引擎写死为开）；之后以用户在设置里的选择为准。
        if !fm.fileExists(atPath: dir.appendingPathComponent(AutoBackupPrefs.fileName).path) {
            try? autoPrefs.setEnabled(true); try? autoPrefs.setRequested(true)
        }
        scheduler = PlannedWakeScheduler(directory: dir, submitter: BGTaskSubmitter(), logger: logger)

        let plane = self.plane
        let epoch: @Sendable () -> String? = {
            guard let r = pairingStore.load(), !r.lost, !r.pairingEpoch.isEmpty else { return nil }
            return r.pairingEpoch
        }
        let desktop = ControlPlaneDesktop(client: ProtoClient(transport: CurrentPeerTransport(plane: plane, store: pairingStore)))
        let delivery = FlowDeliveryPort(provider: FfiBlobProvider(provider: provider), currentEpoch: epoch, desktop: desktop,
                                        push: ControlPlanePush(transport: CurrentPeerTransport(plane: plane, store: pairingStore)), logger: logger, pairingLoss: pairingLoss)
        let media = self.media
        let scope: @Sendable () -> Set<String> = { media.savedScope() ?? [] }
        let settings = self.settings
        let autoPrefs = self.autoPrefs
        let network = self.network
        let model = LiveEngineModel()
        engineModel = model
        engine = FlowEngine(
            store: orders, media: PhotoMediaSource(selected: scope, inbox: inbox),
            importer: PhotoImporter(provider: provider, tempRoot: fm.temporaryDirectory.appendingPathComponent("ppass-originals")),
            delivery: delivery,
            probe: ControlPlaneProbe(currentEpoch: epoch, desktop: desktop, logger: logger, pairingLoss: pairingLoss),
            presence: ControlPlanePresence(desktop: desktop), lease: window, scheduler: scheduler, control: control,
            conditions: {
                Conditions(paired: epoch() != nil, autoBackupEnabled: autoPrefs.enabled(), wifiOnly: settings.wifiOnly(),
                           onUnmetered: !network.isExpensive, batteryLow: BatteryState.isLow)
            },
            inScope: { PhotoMediaSource.inScope(bucketId: $0, selected: scope()) },
            mediaAbsenceTrusted: { media.access() == .full },
            pairingEpoch: epoch, logger: logger,
            onView: { view in Task { await model.engineChanged(view) } }
        )
        catchup = ForegroundCatchup(engine: engine)
        // #977：前台心跳（对位 Android ForegroundHeartbeat）。结果映射在 PPassCore，这里只接线：
        // 可达 → 叫醒引擎（#439）；被拒为配对失效 → 记进 PairingLoss 并刷新首页事实（refreshFacts 据此标红卡，#466）。
        sentinel = SentinelStore(directory: dir, logger: logger)
        let loss = pairingLoss
        heartbeat = ForegroundHeartbeat(
            desktop: desktop, currentEpoch: epoch, ledger: sentinel, now: { Int64(Date().timeIntervalSince1970 * 1000) },
            onReachable: { [engine = self.engine] in
                await engine.onDesktopReachable()
                await model.refresh?()
            },
            onPairingLost: { epoch, failure in
                loss.record(epoch: epoch, failure: failure)
                await model.refresh?()
            },
            logger: logger)
        // #978：前台相册变化 → 重算首页计数 + FOREGROUND_MEDIA_CHANGE 叫醒引擎。生命周期：配对着且相册已授权（完整或部分）
        // 才注册，断开清单注销，重新配对 / 授权后由 `mediaWatcher.start()`（paired / refreshFacts）恢复。
        let window = self.window
        let engine = self.engine
        let change = ForegroundMediaChange(isForeground: { window.isAppActive }, recount: { await model.refresh?() },
                                           trigger: { _ = await engine.trigger($0) }, logger: logger)
        mediaWatcher = MediaChangeWatcher(
            source: PhotoLibraryChangeSource(),
            unavailableReason: {
                guard pairingStore.load() != nil else { return "not paired" }
                return PhotoLibraryChangeSource.unavailableReason(level: PhotoKitAuthorization().currentLevel())
            },
            onChange: { Task { await change.handle() } }, logger: logger)
        PPassBackgroundTasks.register(engine: engine, window: window, scheduler: scheduler, logger: logger)
        scheduler.ensureScheduled()
        PPassBackgroundTasks.ensureShortScheduled(logger: logger)
        if root.isDegraded { logger.log("storage root degraded: \(root.kind)") }
        network.onUpdate = { [weak self] update in self?.networkPathChanged(update) }
    }

    /// #976：路径更新 → 先让 iroh 重探路径，再交给引擎（对位 Android `onFlowNetworkChanged`）：
    /// 整条路径不可用 → 在飞的这张判路径失败；否则当作一次网络变化（跑中切到蜂窝且仅 Wi‑Fi → 停轮等 WIFI）。
    /// 网络从断到通时顺带补发待撤销的 unpair（#956；回前台与启动的触发点在 LiveLifecycle / start）。
    func networkPathChanged(_ update: NetworkPathTracker.Update) {
        if update.recovered { flushPendingUnpairs() }
        let provider = self.provider, engine = self.engine
        Task {
            await dispatchNetworkPath(update, providerNetworkChange: { provider.ffi.networkChange() },
                                      engineLost: { await engine.onNetworkLost() },
                                      engineChanged: { await engine.onNetworkChanged() })
        }
    }

    /// 重试待撤销的 `device.unpair`（#956）。后台协程，失败只写日志，不碰 UI。
    func flushPendingUnpairs() {
        let flusher = unpairFlusher
        Task { await flusher.flush() }
    }

    /// 对外的端口集合（界面只认这几个 protocol）。
    func ports() -> Backend {
        let pairing = LivePairing(plane: plane, store: pairingStore, onboarded: { [onboarded] in onboarded.wasOnboarded($0) },
                                  onPaired: { [weak self] record in self?.paired(record) },
                                  onDisconnect: { [weak self] in await self?.disconnect() },
                                  pending: pendingUnpair, flusher: unpairFlusher)
        let timeline = LiveTimeline(client: { [pairingStore, plane] in
            guard let r = pairingStore.load() else { return nil }
            return ProtoClient(transport: PeerCtrlTransport(plane: plane, peerToken: r.peerToken))
        }, myNodeId: { [plane] in try? plane.nodeId() },
        fetchBlob: { [plane] ticket, dest, progress in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ppass-blobstore")
            return try await plane.fetchBlob(ticket: ticket, scratch: scratch, dest: dest, progress: progress)
        })
        return Backend(isDemo: false, timeline: timeline, media: media, pairing: pairing,
                       engine: LiveEngineAdapter(backend: self))
    }

    private func paired(_ record: PairingRecord) {
        // #956：重新配对同一台电脑，先删它的待撤销条目，否则后台重试会把刚建立的新配对撤掉。
        do { try pendingUnpair.remove(daemonNodeId: record.daemonNodeId) }
        catch { logger.log("unpair-outbox: remove on re-pair failed: \(error)") }
        try? provider.ffi.setAllowedPeer(nodeId: record.daemonNodeId)
        // #935：换了一台电脑就清旧账（已确认计数不能算给新电脑）；同一台重新配对不动。失败要暴露，不静默沿用旧账。
        do { _ = try adoptDesktop(orders, daemonNodeId: record.daemonNodeId, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) }
        catch { logger.log("adoptDesktop failed: \(error)") }
        try? onboarded.markOnboarded(record.daemonNodeId)
        if autoPrefs.requested() { try? autoPrefs.setEnabled(true) } // 断开时只停生产者、留意图（MOB-93）：重新配对按意图恢复
        mediaWatcher.start() // 断开时注销了；重新配对后恢复（#978）
        Task { _ = await engine.trigger(.pairingRepaired) }
    }

    /// 本地断开：先停引擎这一轮，再按断开清单清存储根（配对凭据、唤醒计划、自动备份生产者）。
    /// 身份、相册范围、账本、「连过哪些电脑」都保留——重新扫码后不会重传已备份的。
    func disconnect() async {
        await engine.stopForDisconnect()
        // provider 撤销（#974）、唤醒取消、相册监听注销都在清单的运行时三行里，清文件失败也不会跳过它们。
        let provider = self.provider, scheduler = self.scheduler, watcher = mediaWatcher, logger = self.logger
        let actions = DisconnectActions(stopFlow: { provider.teardownForDisconnect(logger: logger) },
                                        cancelWakes: { scheduler.stop() }, stopMedia: { watcher.stop() })
        do { try applyDisconnectManifest(root: root.url, runtime: actions, logger: logger) } catch {
            logger.log("disconnect manifest failed: \(error)")
        }
        await refreshFacts()
    }

    func start() {
        flushPendingUnpairs() // 启动
        Task {
            await engine.start()
            await refreshFacts()
        }
    }

    func setActive(_ active: Bool) {
        window.setAppActive(active)
        // 心跳只在前台跑（两端一致，没有后台心跳）：回前台立即拍一次，退后台停。
        if active { heartbeat.start() } else { heartbeat.stop() }
        if active {
            scheduler.ensureScheduled()
            PPassBackgroundTasks.ensureShortScheduled(logger: logger)
            Task { _ = await catchup.appDidBecomeActive(); await refreshFacts() }
        }
    }

    /// 首页事实：引擎视图在第一次精确计数（pendingKnown）之前不给（对位 Android visibleEngineView / UI21）。
    func refreshFacts() async {
        mediaWatcher.start() // 幂等；相册授权晚于启动（首次授权）时在这里补注册（#978）
        let known = await engine.pendingKnown
        let view = await engine.view
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // #973：账本读失败不许落成 0（会被首页读成「都存好了」）——记日志，事实标「计数不可读」，投影层不给完成度结论。
        let counts = Result { try OrderCounts.read(from: orders, missingSourceAckAt: control.missingSourceAckAt(), nowMs: nowMs) }
        if case .failure(let error) = counts { logger.log("home-facts: order counts unreadable: \(error)") }
        let facts = FlowFacts(
            view: known ? EngineSnapshot(view) : nil,
            inScopeTotal: media.inScopeTotal(),
            lastReachableAt: sentinel.load().lastReachableAt
        ).applying(counts: counts)
        if pairingLoss.changeCount > 0, let e = pairingStore.load()?.pairingEpoch, pairingLoss.isLost(epoch: e) {
            pairingStore.markLost()
        }
        let refresh = await MainActor.run { () -> BackgroundRefreshAvailability in
            switch UIApplication.shared.backgroundRefreshStatus {
            case .available: return .available
            case .denied: return .denied
            default: return .restricted
            }
        }
        let last = facts.lastSuccessAt > 0 ? Date(timeIntervalSince1970: Double(facts.lastSuccessAt) / 1000) : nil
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let notices = BackupPromise.notices(view: view, backgroundRefresh: refresh, lastConfirmedAt: last, formatTime: { f.string(from: $0) })
        await engineModel.publish(facts, notices)
        // 失败通知：配对失效 / 备份出问题时提醒一次（同一次状况不重复）；开关关着不发。
        if notifyPrefs.enabled() {
            let lost = pairingStore.load()?.lost == true
            let trouble: Bool = { if case .trouble = HomeProjection.backupUiState(facts, noAlbums: false) { return true } else { return false } }()
            await FailureNotifier.update(pairingLost: lost, trouble: trouble, logger: logger)
        }
    }
}

/// 控制面传输：对端 = 当前配对记录里的 peer token（配对 / 重新配对后自动换）。
struct CurrentPeerTransport: CtrlTransport {
    let plane: ControlPlane
    let store: PairingStore
    struct NotPaired: Error {}

    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        guard let r = store.load() else { throw NotPaired() }
        return try await plane.call(peerToken: r.peerToken, method: method, paramsJSON: paramsJSON, timeoutMs: timeoutMs)
    }
}

extension CurrentPeerTransport: CtrlStreamTransport {
    func stream(method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws {
        guard let r = store.load() else { throw NotPaired() }
        try await plane.stream(peerToken: r.peerToken, method: method, paramsJSON: paramsJSON, onFrame: onFrame)
    }
}

/// 引擎视图变化 → 主线程上的事实快照 + 回调。
actor LiveEngineModel {
    private(set) var facts = FlowFacts()
    private(set) var notices: [PromiseNotice] = []
    private var listeners: [@Sendable () -> Void] = []
    var refresh: (@Sendable () async -> Void)?

    func setRefresh(_ r: @escaping @Sendable () async -> Void) { refresh = r }
    func add(_ l: @escaping @Sendable () -> Void) { listeners.append(l) }
    func engineChanged(_ view: EngineView) async { await refresh?() }

    func publish(_ f: FlowFacts, _ n: [PromiseNotice]) {
        facts = f
        notices = n
        for l in listeners { DispatchQueue.main.async { l() } }
    }
}

/// `BackupEngine` 端口的真实现。
final class LiveEngineAdapter: BackupEngine, @unchecked Sendable {
    private let backend: LiveBackend
    private let lock = NSLock()
    private var latest = FlowFacts()
    private var latestNotices: [PromiseNotice] = []

    init(backend: LiveBackend) {
        self.backend = backend
        Task {
            await backend.engineModel.setRefresh { [weak backend] in await backend?.refreshFacts() }
            await backend.engineModel.add { [weak self] in self?.pull() }
        }
    }

    private func pull() {
        Task {
            let f = await backend.engineModel.facts
            let n = await backend.engineModel.notices
            lock.lock(); latest = f; latestNotices = n; lock.unlock()
            await MainActor.run { self.listeners.forEach { $0() } }
        }
    }

    @MainActor private var listeners: [() -> Void] = []

    func facts() -> FlowFacts { lock.lock(); defer { lock.unlock() }; return latest }
    func promise() -> [PromiseNotice] { lock.lock(); defer { lock.unlock() }; return latestNotices }

    func observe(_ onChange: @escaping () -> Void) {
        Task { @MainActor in self.listeners.append(onChange) }
    }

    func pauseOrResume() async {
        let view = await backend.engine.view
        if view.state == .paused { _ = await backend.engine.resume() } else { _ = await backend.engine.pause() }
        await backend.refreshFacts()
    }

    func autoBackup() -> Bool { backend.autoPrefs.enabled() }
    func setAutoBackup(_ on: Bool) {
        try? backend.autoPrefs.setEnabled(on)
        try? backend.autoPrefs.setRequested(on)
        Task { await backend.refreshFacts() } // 只改策略，不凭空起一轮（Android 同：开关只存偏好）
    }

    func remainingSnapshot() async -> RemainingSnapshot? { try? await backend.engine.remainingSnapshot() }

    func cancelRemaining(_ snapshot: RemainingSnapshot) async -> Int? {
        let n = try? await backend.engine.cancelRemaining(snapshot)
        await backend.refreshFacts()
        return n ?? nil
    }

    func restoreSkipped() async {
        _ = try? await backend.engine.restoreSkipped()
        await backend.refreshFacts()
    }

    func acknowledgeMissingSource() {
        Task { await backend.engine.acknowledgeMissingSource(); await backend.refreshFacts() }
    }

    func notifyOnFailure() -> Bool { backend.notifyPrefs.enabled() }
    func setNotifyOnFailure(_ on: Bool) {
        do { try backend.notifyPrefs.setEnabled(on) } catch { backend.logger.log("notify-prefs: write failed: \(error)") }
    }

    func notificationAuthorization() async -> NotificationAuthorization { await SystemNotifications.authorization() }
    func requestNotificationAuthorization() async -> NotificationAuthorization {
        let granted = await SystemNotifications.request()
        let now = await SystemNotifications.authorization()
        backend.logger.log("notifications: system prompt result granted=\(granted) status=\(now)")
        return now
    }
    @MainActor func openNotificationSettings() { SystemNotifications.openSettings() }

    func shouldAskNotificationAtOnboarding() async -> Bool {
        backend.notificationAsk.shouldAsk(authorization: await SystemNotifications.authorization())
    }

    /// 完成页点「好」：该问就先落盘「问过」再弹，结果同步回开关（Android `thenContinue` + `onResult`）。
    func askNotificationAtOnboarding() async {
        let auth = await SystemNotifications.authorization()
        guard backend.notificationAsk.shouldAsk(authorization: auth) else { return }
        do { try backend.notificationAsk.markAsked() } catch {
            // 落不了盘就不弹：宁可少问，不许因为没记住而下次又问。
            backend.logger.log("notification-ask: markAsked failed, skip prompt: \(error)"); return
        }
        let after = await requestNotificationAuthorization()
        do { try backend.notificationAsk.onResult(granted: after == .authorized, prefs: backend.notifyPrefs) }
        catch { backend.logger.log("notification-ask: sync toggle failed: \(error)") }
    }

    func wifiOnly() -> Bool { backend.settings.wifiOnly() }
    func setWifiOnly(_ on: Bool) {
        try? backend.settings.save(wifiOnly: on)
        Task {
            // 只有「正因为 Wi-Fi 在等」时放宽条件才有事可做：叫醒一轮接着传；其余情况不起轮。
            if !on, await backend.engine.view.waitReason == .wifi { _ = await backend.engine.trigger(.manual) }
            await backend.refreshFacts()
        }
    }

    func wake() async {
        _ = await backend.engine.trigger(.scopeAdded)
        await backend.refreshFacts()
    }

    func retryFailed() async {
        _ = try? await backend.engine.retryFailed()
        await backend.refreshFacts()
    }
}

/// 路径来源：生产是 `NWPathMonitor`，测试里换成假的，按需喂「可用 / 昂贵」。
protocol NetworkPathSource: AnyObject {
    func start(_ handler: @escaping @Sendable (_ satisfied: Bool, _ expensive: Bool, _ interfaces: [String]) -> Void)
}

final class NWPathSource: NetworkPathSource {
    private let monitor = NWPathMonitor()
    func start(_ handler: @escaping @Sendable (Bool, Bool, [String]) -> Void) {
        monitor.pathUpdateHandler = { handler($0.status == .satisfied, $0.isExpensive, $0.availableInterfaces.map(\.name)) }
        monitor.start(queue: DispatchQueue(label: "ppass.network"))
    }
}

/// 当前网络是否「昂贵」（蜂窝 / 个人热点）——「仅 Wi‑Fi」的判据；并把每次路径更新交给 `onUpdate`（对位 Android
/// `registerNetworkCallback` → `onFlowNetworkChanged`）。进程活着就一直监听，前台、宽限期、后台任务窗口都算。
final class NetworkState: @unchecked Sendable {
    private let source: NetworkPathSource
    private let lock = NSLock()
    private var expensive = false
    private var tracker = NetworkPathTracker()
    /// 每次路径更新一次；首次回调的 `action` 为 nil（启动由 `LiveBackend.start` 管）。在 monitor 队列上调用。
    var onUpdate: ((NetworkPathTracker.Update) -> Void)?

    init(source: NetworkPathSource = NWPathSource()) {
        self.source = source
        source.start { [weak self] satisfied, expensive, interfaces in
            guard let self else { return }
            self.lock.lock()
            self.expensive = expensive
            let update = self.tracker.update(satisfied: satisfied, signature: "\(satisfied)|\(expensive)|\(interfaces.joined(separator: ","))")
            self.lock.unlock()
            self.onUpdate?(update)
        }
    }

    var isExpensive: Bool { lock.lock(); defer { lock.unlock() }; return expensive }
}

/// 电量低（≤15% 且没插电，阈值在 PPassCore `BatteryPolicy`，与 Android 同口径 #980）。UIDevice 只能在主线程读，所以在主线程上监听并缓存，引擎从任意线程读缓存。
final class BatteryState: @unchecked Sendable {
    static let shared = BatteryState()
    private let lock = NSLock()
    private var low = false

    static var isLow: Bool { shared.lock.lock(); defer { shared.lock.unlock() }; return shared.low }

    @MainActor func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        update()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in BatteryState.shared.update() }
            }
        }
    }

    @MainActor private func update() {
        let value = BatteryPolicy.isLow(level: UIDevice.current.batteryLevel, unplugged: UIDevice.current.batteryState == .unplugged)
        lock.lock(); low = value; lock.unlock()
    }
}

/// 断开清单里的运行时生产者（#974）。引擎这一轮由 `LiveBackend.disconnect` 在清单之前就停好；
/// 三项各接真逻辑：provider 撤销、取消 BGTask 唤醒、注销相册监听。
struct DisconnectActions: DisconnectRuntime {
    let stopFlow: () -> Void
    let cancelWakes: () -> Void
    let stopMedia: () -> Void
    func stopFlowRuntime() { stopFlow() }
    func cancelScheduledWakes() { cancelWakes() }
    func stopMediaChangeObserver() { stopMedia() }
}
