import Foundation
import Network
import PPassBackgroundTasks
import PPassCore
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
    let pairingLoss = PairingLoss()
    let network = NetworkState()
    let engineModel: LiveEngineModel

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
        media = LiveMediaLibrary { BackupScopeStore(directory: dir, daemonNodeId: pairingStore.load()?.daemonNodeId, logger: logger) }
        provider = try NativeProvider(root: dir)
        try? provider.ffi.setAllowedPeer(nodeId: pairingStore.load()?.daemonNodeId)
        orders = try SQLiteOrderStore(directory: dir, logger: logger)
        control = FlowControlStore(directory: dir, logger: logger)
        settings = BackupSettings(directory: dir, logger: logger)
        scheduler = PlannedWakeScheduler(directory: dir, submitter: BGTaskSubmitter(), logger: logger)

        let plane = self.plane
        let epoch: @Sendable () -> String? = {
            guard let r = pairingStore.load(), !r.lost, !r.pairingEpoch.isEmpty else { return nil }
            return r.pairingEpoch
        }
        let desktop = ControlPlaneDesktop(client: ProtoClient(transport: CurrentPeerTransport(plane: plane, store: pairingStore)))
        let delivery = FlowDeliveryPort(provider: FfiBlobProvider(provider: provider), currentEpoch: epoch, desktop: desktop,
                                        push: UnsupportedPush(), logger: logger, pairingLoss: pairingLoss)
        let media = self.media
        let scope: @Sendable () -> Set<String> = { media.savedScope() ?? [] }
        let settings = self.settings
        let network = self.network
        let model = LiveEngineModel()
        engineModel = model
        engine = FlowEngine(
            store: orders, media: PhotoMediaSource(selected: scope),
            importer: PhotoImporter(provider: provider, tempRoot: fm.temporaryDirectory.appendingPathComponent("ppass-originals")),
            delivery: delivery,
            probe: ControlPlaneProbe(currentEpoch: epoch, desktop: desktop, logger: logger, pairingLoss: pairingLoss),
            presence: ControlPlanePresence(desktop: desktop), lease: window, scheduler: scheduler, control: control,
            conditions: {
                Conditions(paired: epoch() != nil, autoBackupEnabled: true, wifiOnly: settings.wifiOnly(),
                           onUnmetered: !network.isExpensive, batteryLow: BatteryState.isLow)
            },
            inScope: { PhotoMediaSource.inScope(bucketId: $0, selected: scope()) },
            mediaAbsenceTrusted: { media.access() == .full },
            pairingEpoch: epoch, logger: logger,
            onView: { view in Task { await model.engineChanged(view) } }
        )
        catchup = ForegroundCatchup(engine: engine)
        PPassBackgroundTasks.register(engine: engine, window: window, scheduler: scheduler, logger: logger)
        scheduler.ensureScheduled()
        if root.isDegraded { logger.log("storage root degraded: \(root.kind)") }
    }

    /// 对外的端口集合（界面只认这几个 protocol）。
    func ports() -> Backend {
        let pairing = LivePairing(plane: plane, store: pairingStore, onboarded: { [onboarded] in onboarded.wasOnboarded($0) }) { [weak self] record in
            self?.paired(record)
        } onDisconnect: { [weak self] in
            await self?.disconnect()
        }
        let timeline = LiveTimeline(client: { [pairingStore, plane] in
            guard let r = pairingStore.load() else { return nil }
            return ProtoClient(transport: PeerCtrlTransport(plane: plane, peerToken: r.peerToken))
        }, myNodeId: { [plane] in try? plane.nodeId() })
        return Backend(isDemo: false, timeline: timeline, media: media, pairing: pairing,
                       engine: LiveEngineAdapter(backend: self))
    }

    private func paired(_ record: PairingRecord) {
        try? provider.ffi.setAllowedPeer(nodeId: record.daemonNodeId)
        try? onboarded.markOnboarded(record.daemonNodeId)
        Task { _ = await engine.trigger(.pairingRepaired) }
    }

    /// 本地断开：先停引擎这一轮，再按断开清单清存储根（配对凭据、唤醒计划、自动备份生产者）。
    /// 身份、相册范围、账本、「连过哪些电脑」都保留——重新扫码后不会重传已备份的。
    func disconnect() async {
        await engine.stopForDisconnect()
        do { try applyDisconnectManifest(root: root.url, runtime: DisconnectActions(scheduler: scheduler), logger: logger) } catch {
            logger.log("disconnect manifest failed: \(error)")
        }
        try? provider.ffi.setAllowedPeer(nodeId: nil)
        await refreshFacts()
    }

    func start() {
        Task {
            await engine.start()
            await refreshFacts()
        }
    }

    func setActive(_ active: Bool) {
        window.setAppActive(active)
        if active {
            scheduler.ensureScheduled()
            Task { _ = await catchup.appDidBecomeActive(); await refreshFacts() }
        }
    }

    /// 首页事实：引擎视图在第一次精确计数（pendingKnown）之前不给（对位 Android visibleEngineView / UI21）。
    func refreshFacts() async {
        let known = await engine.pendingKnown
        let view = await engine.view
        let all = (try? orders.countCurrentByState(bucketIds: nil)) ?? [:]
        let facts = FlowFacts(
            view: known ? EngineSnapshot(view) : nil,
            confirmed: (try? orders.countConfirmedPresent(bucketIds: nil)) ?? 0,
            inScopeTotal: media.inScopeTotal(),
            failed: all[.failed] ?? 0,
            unfinished: (all[.pending] ?? 0) + (all[.transferring] ?? 0) + (all[.failed] ?? 0),
            lastSuccessAt: (try? orders.lastConfirmedAtMs()) ?? 0,
            missingSourceUnacknowledged: 0,
            skippedByUser: all[.skippedByUser] ?? 0)
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

    func wifiOnly() -> Bool { backend.settings.wifiOnly() }
    func setWifiOnly(_ on: Bool) {
        try? backend.settings.save(wifiOnly: on)
        Task { _ = await backend.engine.trigger(.scopeAdded); await backend.refreshFacts() } // 放宽条件后立即重评一轮
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

/// 当前网络是否「昂贵」（蜂窝 / 个人热点）——「仅 Wi‑Fi」的判据。
final class NetworkState: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock(); self?.expensive = path.isExpensive; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "ppass.network"))
    }

    var isExpensive: Bool { lock.lock(); defer { lock.unlock() }; return expensive }
}

/// 电量低（<20% 且没插电）。UIDevice 只能在主线程读，所以在主线程上监听并缓存，引擎从任意线程读缓存。
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
        let level = UIDevice.current.batteryLevel
        let value = level >= 0 && level < 0.2 && UIDevice.current.batteryState == .unplugged
        lock.lock(); low = value; lock.unlock()
    }
}

/// 断开清单里的运行时生产者。引擎这一轮由 `LiveBackend.disconnect` 在清单之前就停好；iOS 目前没有注册 PHPhotoLibrary 变更监听。
struct DisconnectActions: DisconnectRuntime {
    let scheduler: PlannedWakeScheduler
    func stopFlowRuntime() {}
    func cancelScheduledWakes() { scheduler.stop() }
    func stopMediaChangeObserver() {}
}
