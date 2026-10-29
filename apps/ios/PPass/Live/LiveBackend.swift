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
    let providerParker: ProviderIdleParker
    let orders: SQLiteOrderStore
    let control: FlowControlStore
    let settings: BackupSettings
    let autoPrefs: AutoBackupPrefs
    let notifyPrefs: NotifyOnFailurePrefs
    let noticeStore: DefinitiveNoticeStore
    let pairingLoss = PairingLoss()
    let sentinel: SentinelStore
    let heartbeat: ForegroundHeartbeat
    /// 照片页实时更新（#963）：订阅跟前台心跳同一层，前台开、后台关。
    let timelineLive: LiveTimelineFeed
    let network = NetworkState()
    let engineModel: LiveEngineModel
    /// 前台相册变化监听（#978，对位 Android BackupUiStateHolder 的 MediaStore ContentObserver）。
    let mediaWatcher: MediaChangeWatcher
    /// 被拒即清理（#1119）：所有路径发现「电脑已不认这台手机」都汇到这里，幂等。
    private(set) var rejectedCleanup: RejectedPairingCleanup!
    private let timelineLock = NSLock()
    private var liveTimeline: LiveTimeline?
    #if DEBUG
    /// 真机验证用的私钥指纹（BLAKE3 前 8 位）；Release 没有这个字段。
    let identityFingerprint: String
    #endif

    /// 存储根：App 私有容器 Application Support 下的 `PPass/`（#1172：不放 App Group，见 [StorageRoot]）。
    static func resolveRoot(logger: CoreLogger) throws -> StorageRoot {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try StorageRoot.resolve(appPrivateDirectory: appSupport, logger: logger)
    }

    /// 身份换新时清掉旧配对：此刻引擎还没建，只有 BGTask 里挂着的唤醒要撤（唤醒计划文件由清单的 clear 行删）。
    static func clearPairingBeforeStart(root: URL, logger: CoreLogger) throws {
        try applyDisconnectManifest(root: root, runtime: DisconnectActions(stopFlow: {}, cancelWakes: { BGTaskSubmitter().cancelAll() }, stopMedia: {}, clearThumbs: {}),
                                    logger: logger, external: .system)
    }

    /// 拒绝启动页的「重置并重新配对」：换新私钥、清本地配对（DeviceIdentity.becomeNewDevice），之后重新起 App 即回到扫码。
    static func resetIdentity(store: IdentitySecretStore = KeychainIdentityStore()) throws {
        let logger = OSLogger()
        let dir = try resolveRoot(logger: logger).url
        _ = try DeviceIdentity.becomeNewDevice(root: dir, store: store, reason: .userReset,
                                               clearPairing: { try clearPairingBeforeStart(root: dir, logger: logger) }, logger: logger)
    }

    /// 起 App 的第一件事是取身份：读不到钥匙串（开机后还没解锁过）抛 `IdentityStoreError.locked`，
    /// 钥匙串故障抛 `IdentityStoreError` 其余几种——都在碰任何存储之前（AppBoot 据此分流）。
    init(identityStore: IdentitySecretStore = KeychainIdentityStore()) throws {
        let fm = FileManager.default
        let logger = self.logger
        root = try Self.resolveRoot(logger: logger)
        let dir = root.url
        let identity = try DeviceIdentity.load(root: dir, store: identityStore,
                                               clearPairing: { try Self.clearPairingBeforeStart(root: dir, logger: logger) }, logger: logger)
        plane = ControlPlane(secretKey: identity.key)
        #if DEBUG
        identityFingerprint = String(blake3Hex(data: identity.key).prefix(8))
        #endif
        pairingStore = PairingStore(root: dir)
        if let record = pairingStore.load() { LogRedact.registerDeviceNames([record.storageDeviceName]) } // #1152：电脑名不进日志
        onboarded = OnboardedDesktopsStore(directory: dir, logger: logger)
        let pairingStore = self.pairingStore
        // #1124：任何一条连接（请求、探测、订阅流、取原图）被「记录里的那台电脑」以 401 / 410 关掉 ⇒ 立刻记成配对失效，
        // 走被拒即清理（setOnLost 在后面接上）；别的关闭方、别的码一律当连不上，不动配对。
        // 控制面与上传 provider（#1126）的关闭监听共用同一个处理。
        let onClosed = desktopCloseHandler(pairingStore: pairingStore, loss: pairingLoss, logger: logger)
        plane.setOnPeerClosed(onClosed)
        UnpairNotice.removeLegacyOutbox(root: dir, logger: logger) // #956 撤销：老版本的断开发件箱（含旧电脑 peerToken）
        media = LiveMediaLibrary { BackupScopeStore(directory: dir, daemonNodeId: pairingStore.load()?.daemonNodeId, logger: logger) }
        provider = try NativeProvider(root: dir, onPeerClosed: onClosed)
        provider.applyAllowedPeer(pairingStore.load()?.daemonNodeId, context: "startup", logger: logger)
        let parker = ProviderIdleParker(provider: provider, logger: logger)
        providerParker = parker
        orders = try SQLiteOrderStore(directory: dir, logger: logger)
        // 收件箱（#958）：与账本同一个文件、独立的表和连接。必须在账本之后打开——账本发现文件损坏会删掉整个文件重建。
        let inbox = try Inbox(path: orders.path, history: PhotoKitChangeHistory(), log: { logger.log($0) })
        control = FlowControlStore(directory: dir, logger: logger)
        settings = BackupSettings(directory: dir, logger: logger)
        autoPrefs = AutoBackupPrefs(directory: dir, logger: logger)
        notifyPrefs = NotifyOnFailurePrefs(directory: dir, logger: logger)
        noticeStore = DefinitiveNoticeStore(directory: dir, logger: logger)
        // #1262：通知默认关；老用户升级保持原状态。必须在任何 markOnboarded 之前定老用户（新装用户此刻没有配对、没走过 onboarding）。
        notifyPrefs.initIfAbsent(existingUser: pairingStore.load() != nil || onboarded.anyOnboarded())
        // 全新安装后台备份默认关（对位 Android `AutoBackupPrefs.autoEnabled = false`，#982）：首次配对完成页由用户选开不开。
        // #1119：未配对不向系统挂任何后台任务（启动 / 回前台 / 引擎登记唤醒 / 短任务续挂都过这道门）。
        scheduler = PlannedWakeScheduler(directory: dir, submitter: BGTaskSubmitter(), logger: logger, isPaired: { pairingStore.load() != nil })

        let plane = self.plane
        let pairingId: @Sendable () -> String? = {
            guard let r = pairingStore.load(), !r.lost, !r.pairingId.isEmpty else { return nil }
            return r.pairingId
        }
        // #1119：hello 成功但没有 / 不是本地的 pairing_id，等同被拒（not_paired / pairing_mismatch），一律走「被拒」路径。
        let desktop = ControlPlaneDesktop(client: ProtoClient(transport: CurrentPeerTransport(plane: plane, store: pairingStore)), localPairingId: pairingId)
        let delivery = FlowDeliveryPort(provider: FfiBlobProvider(provider: provider), currentPairingId: pairingId, desktop: desktop,
                                        push: ControlPlanePush(transport: CurrentPeerTransport(plane: plane, store: pairingStore)), logger: logger, pairingLoss: pairingLoss)
        let media = self.media
        // 读盘失败与「从未保存」都给引擎空范围（一张都不备份），但读失败要留日志，不能和从未保存混为一谈（#971）。
        let scope: @Sendable () -> Set<String> = {
            do { return try media.savedScope() ?? [] } catch {
                logger.log("backup-scope: unreadable, engine sees an empty scope: \(error)")
                return []
            }
        }
        let settings = self.settings
        let autoPrefs = self.autoPrefs
        let network = self.network
        let model = LiveEngineModel()
        engineModel = model
        // #966：审计 outbox 冲刷（对位 Android `dispatcher`）。确认删除要回到引擎的单写者上，而引擎此刻还没建好——用盒子延后绑定。
        let engineBox = EngineBox()
        let audit = AuditOutboxDispatcher(
            store: orders, desktop: FlowWiring.auditDesktop(store: pairingStore, desktop: desktop),
            acknowledge: { ids in await engineBox.engine?.acknowledgeAudit(ids) })
        engine = FlowEngine(
            store: orders, media: PhotoMediaSource(selected: scope, inbox: inbox, log: { logger.log($0) }),
            importer: PhotoImporter(provider: provider, tempRoot: fm.temporaryDirectory.appendingPathComponent("ppass-originals")),
            delivery: delivery,
            probe: PrewarmingProbe(provider: provider,
                                   inner: ControlPlaneProbe(currentPairingId: pairingId, desktop: desktop, logger: logger, pairingLoss: pairingLoss),
                                   logger: logger),
            presence: ControlPlanePresence(desktop: desktop), lease: window, scheduler: scheduler, control: control,
            conditions: {
                Conditions(paired: pairingId() != nil, autoBackupEnabled: autoPrefs.enabled(), wifiOnly: settings.wifiOnly(),
                           onUnmetered: !network.isExpensive, batteryLow: BatteryState.isLow)
            },
            inScope: { PhotoMediaSource.inScope(bucketId: $0, selected: scope()) },
            mediaAbsenceTrusted: { media.access() == .full },
            pairingId: pairingId, logger: logger,
            afterCycle: FlowWiring.afterCycle(dispatcher: audit),
            onPairingIdAdvertised: FlowWiring.pairingIdAdvertised(loss: pairingLoss, currentPairingId: pairingId),
            onView: { view in Task { await model.engineChanged(view) } }
        )
        engineBox.engine = engine
        catchup = ForegroundCatchup(engine: engine)
        // #977：前台心跳（对位 Android ForegroundHeartbeat）。结果映射在 PPassCore，这里只接线：
        // 可达 → 叫醒引擎（#439）；被拒为配对失效 → 记进 PairingLoss 并刷新首页事实（refreshFacts 据此标红卡，#466）。
        sentinel = SentinelStore(directory: dir, logger: logger)
        let loss = pairingLoss
        let liveFeed = LiveTimelineFeed(transport: CurrentPeerTransport(plane: plane, store: pairingStore),
                                        isPaired: { pairingStore.load() != nil }, logger: logger)
        timelineLive = liveFeed
        heartbeat = ForegroundHeartbeat(
            desktop: desktop, currentPairingId: pairingId, ledger: sentinel, now: { Int64(Date().timeIntervalSince1970 * 1000) },
            onReachable: { [engine = self.engine] in
                await engine.onDesktopReachable()
                liveFeed.session.onDesktopReachable() // 实时更新退避耗尽后桌面回来了：自动恢复，不等用户点「重试」（Android #474）
                await model.refresh?()
            },
            onPairingLost: { pairingId, failure in
                loss.record(pairingId: pairingId, failure: failure)
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
        scheduler.ensureScheduled()
        scheduler.ensureShortScheduled()
        network.onUpdate = { [weak self] update in self?.networkPathChanged(update) }
        // #1119：被拒即清理。回调可能被多条路径重复触发、也可能在引擎一轮里同步触发，所以只派一个 Task 出去，清理本身幂等。
        rejectedCleanup = RejectedPairingCleanup(
            localPairingId: { pairingStore.load()?.pairingId },
            announce: { [weak self] id in await self?.evaluateNotices(assumeLostPairingId: id) },
            clear: { [weak self] in await self?.disconnect() },
            logger: logger)
        pairingLoss.setOnLost { [weak self] id in
            guard let self else { return }
            Task { await self.rejectedCleanup.handle(rejectedPairingId: id) }
        }
    }

    /// 缩略图的内存缓存（`ports()` 造出的那个时间线持有它）；还没造出来就没有可清的。
    private func clearThumbnailMemoryCache() {
        timelineLock.lock(); let timeline = liveTimeline; timelineLock.unlock()
        timeline?.clearMemoryCache()
    }

    /// #976：路径更新 → 先让 iroh 重探路径，再交给引擎（对位 Android `onFlowNetworkChanged`）：
    /// 整条路径不可用 → 在飞的这张判路径失败；否则当作一次网络变化（跑中切到蜂窝且仅 Wi‑Fi → 停轮等 WIFI）。
    func networkPathChanged(_ update: NetworkPathTracker.Update) {
        let provider = self.provider, engine = self.engine
        Task {
            await dispatchNetworkPath(update, providerNetworkChange: { provider.ffi.networkChange() },
                                      engineLost: { await engine.onNetworkLost() },
                                      engineChanged: { await engine.onNetworkChanged() })
        }
    }

    /// 后台任务被叫醒时用的那一套（注册在 AppBoot，不在这里：见 PPassBackgroundTasks.register）。
    /// #981：后台任务跑完、交还系统之前评估一次通知（对位 Android BackupWorker 结束时的评估）。
    func backgroundTarget() -> BackgroundTarget {
        BackgroundTarget(engine: engine, window: window, scheduler: scheduler, afterRun: { [weak self] in await self?.evaluateNotices() })
    }

    /// 对外的端口集合（界面只认这几个 protocol）。
    func ports() -> Backend {
        let pairing = LivePairing(transportFor: { [plane] in PeerCtrlTransport(plane: plane, peerToken: $0) }, store: pairingStore, onboarded: { [onboarded] in onboarded.wasOnboarded($0) },
                                  onPaired: { [weak self] record, known in self?.paired(record, knownDesktop: known) ?? false },
                                  onDisconnect: { [weak self] in await self?.disconnect() }, logger: logger,
                                  localNodeId: { [plane] in try plane.nodeId() })
        let timeline = LiveTimeline(client: { [pairingStore, plane] in
            guard let r = pairingStore.load() else { return nil }
            return ProtoClient(transport: PeerCtrlTransport(plane: plane, peerToken: r.peerToken))
        }, myNodeId: { [plane] in try? plane.nodeId() },
        fetchBlob: { [plane] ticket, dest, progress in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(OriginalCachePaths.fetchScratchDirName)
            return try await plane.fetchBlob(ticket: ticket, scratch: scratch, dest: dest, progress: progress)
        }, logger: logger)
        timelineLock.lock(); liveTimeline = timeline; timelineLock.unlock()
        return Backend(isDemo: false, timeline: timeline, live: timelineLive, media: media, pairing: pairing,
                       engine: LiveEngineAdapter(backend: self))
    }

    /// 返回 true = 要提示用户「设置没存上」（见 `applyAutoBackupOnPairing`）。
    private func paired(_ record: PairingRecord, knownDesktop: Bool) -> Bool {
        provider.applyAllowedPeer(record.daemonNodeId, context: "paired", logger: logger)
        // #935：换了一台电脑就清旧账（已确认计数不能算给新电脑）；同一台重新配对不动。失败要暴露，不静默沿用旧账。
        do { _ = try adoptDesktop(orders, daemonNodeId: record.daemonNodeId, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) }
        catch { logger.log("adoptDesktop failed: \(error)") }
        // 「连过这台电脑」不在这里记：要等用户走完首次设置，在完成页落盘（#1019，对位 Android finishOnboarding）。
        let settingSaveFailed = applyAutoBackupOnPairing(autoPrefs, knownDesktop: knownDesktop, logger: logger)
        mediaWatcher.start() // 断开时注销了；重新配对后恢复（#978）
        timelineLive.session.pairingChanged() // 新配对：按新对端重建实时订阅（#963）
        Task { _ = await engine.trigger(.pairingRepaired) }
        return settingSaveFailed
    }

    /// 本地断开：先停引擎这一轮，再按断开清单清存储根（配对凭据、唤醒计划、自动备份生产者）与原图缓存。
    /// 身份、相册范围、账本、「连过哪些电脑」都保留——重新扫码后不会重传已备份的。
    /// 用户手动断开（`LivePairing.disconnect` 通知电脑之后）、被拒即清理、配对失效卡的「重新连接」共用这一份，本身不发任何通知。
    func disconnect() async {
        await engine.stopForDisconnect()
        // provider 撤销（#974）、唤醒取消、相册监听注销都在清单的运行时三行里，清文件失败也不会跳过它们。
        let provider = self.provider, scheduler = self.scheduler, watcher = mediaWatcher, logger = self.logger
        let actions = DisconnectActions(stopFlow: { provider.teardownForDisconnect(logger: logger) },
                                        cancelWakes: { scheduler.stop() }, stopMedia: { watcher.stop() },
                                        clearThumbs: { [weak self] in self?.clearThumbnailMemoryCache() })
        do { try applyDisconnectManifest(root: root.url, runtime: actions, logger: logger, external: .system) } catch {
            logger.log("disconnect manifest failed: \(error)")
        }
        timelineLive.session.pairingChanged() // 配对已清：旧订阅关掉，空闲等下次配对（#963）
        await refreshFacts()
    }

    func start() {
        let parker = providerParker
        window.observeLease { held in parker.setEngineBusy(held) } // #979：对位 Android engine.status → setEngineBusy
        Task {
            await engine.start()
            await refreshFacts()
        }
    }

    func setActive(_ active: Bool) {
        window.setAppActive(active)
        providerParker.setForeground(active) // #979：不在前台且引擎空闲 → 回收 provider endpoint
        // 心跳只在前台跑（两端一致，没有后台心跳）：回前台立即拍一次，退后台停。
        if active { heartbeat.start(); timelineLive.session.start() } else { heartbeat.stop(); timelineLive.session.stop() }
        if active {
            scheduler.ensureScheduled()
            scheduler.ensureShortScheduled()
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
        if pairingLoss.changeCount > 0, let e = pairingStore.load()?.pairingId, pairingLoss.isLost(pairingId: e) {
            do { try pairingStore.markLost() } catch { logger.log("pairing lost: cannot persist (\(error))") }
        }
        await engineModel.publish(facts, await Self.currentBackgroundRefresh())
        await evaluateNotices()
    }

    @MainActor private static func backgroundRefreshOnMain() -> BackgroundRefreshAvailability {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return .available
        case .denied: return .denied
        default: return .restricted
        }
    }

    static func currentBackgroundRefresh() async -> BackgroundRefreshAvailability {
        await MainActor.run { backgroundRefreshOnMain() }
    }

    /// 失败通知（#981，对位 Android `evaluateDefinitiveEvents`）：进程启动 / 回前台 / 刷新首页事实 / 后台任务结束都走这里。
    /// 只看确定事件（配对失效、相册权限变差、后台刷新被关），不看首页的 Trouble。
    /// [assumeLostPairingId]：被拒即清理在删配对记录**之前**发提示用（此刻盘上还没有 lost 标记）。
    func evaluateNotices(assumeLostPairingId: String? = nil) async {
        let record = pairingStore.load()
        let pairingId = record.map(\.pairingId).flatMap { $0.isEmpty ? nil : $0 }
        let facts = DefinitiveFacts(
            pairingId: pairingId,
            pairingLost: record?.lost == true || (assumeLostPairingId != nil && assumeLostPairingId == pairingId),
            mediaAccess: LiveMediaLibrary.tier(PhotoKitAuthorization().currentLevel()),
            backgroundRequested: autoPrefs.requested(),
            backgroundRefresh: await Self.currentBackgroundRefresh())
        await FailureNotifier.evaluate(facts: facts, notifyEnabled: notifyPrefs.enabled(), store: noticeStore, logger: logger)
    }
}

/// 构造期的引擎引用（审计冲刷的 acknowledge 在引擎建好之前就要成形）。
final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FlowEngine?
    var engine: FlowEngine? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// 控制面传输：对端 = 当前配对记录里的 peer token（配对 / 重新配对后自动换）。
/// #1122：调用因为连接被「记录里的那台电脑」以 401 / 410 关闭而失败 → 翻成与 `not_paired` 应答同一个 [DesktopRejected]，
/// 汇入同一条被拒即清理路径；其它一切原样抛出（按「连不上」处理）。流式调用与取原图不在这里翻译：#1124 起共享 Rust 核心的
/// 关闭监听（`ControlPlane.setOnPeerClosed`，LiveBackend 接线）对每一条连接都上报，立即触发清理。
struct CurrentPeerTransport: CtrlTransport {
    let plane: PeerCallPlane
    let store: PairingStore
    struct NotPaired: Error {}

    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        guard let r = store.load() else { throw NotPaired() }
        do {
            return try await plane.call(peerToken: r.peerToken, method: method, paramsJSON: paramsJSON, timeoutMs: timeoutMs)
        } catch {
            throw translateDesktopClose(error, recordedDaemonNodeId: r.daemonNodeId, method: method)
        }
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
    private(set) var backgroundRefresh: BackgroundRefreshAvailability = .available
    private var listeners: [@Sendable () -> Void] = []
    var refresh: (@Sendable () async -> Void)?

    func setRefresh(_ r: @escaping @Sendable () async -> Void) { refresh = r }
    func add(_ l: @escaping @Sendable () -> Void) { listeners.append(l) }
    func engineChanged(_ view: EngineView) async { await refresh?() }

    func publish(_ f: FlowFacts, _ r: BackgroundRefreshAvailability) {
        facts = f
        backgroundRefresh = r
        for l in listeners { DispatchQueue.main.async { l() } }
    }
}

/// `BackupEngine` 端口的真实现。
/// 配对成功后的后台备份意图（#982，对位 Android 配对结局）：断开时只停生产者、留意图（MOB-93）——连回以前连过的电脑
/// 按意图恢复；换新电脑 = 新的信任关系，清意图，由完成页让用户重新选。
/// 返回 true = 要提示用户：换新电脑清意图没写下来（#1039）。不拦配对；完成页点按钮时按用户的选择再写一次，
/// 否则旧电脑留下的意图会被带到新电脑上。老电脑按意图恢复失败只记日志（Android `settingsWriter.quiet`）：
/// 意图还在盘上，也没有用户在等这一步的结果。
func applyAutoBackupOnPairing(_ prefs: AutoBackupPrefs, knownDesktop: Bool, logger: CoreLogger) -> Bool {
    do {
        try prefs.applyOnPairing(knownDesktop: knownDesktop)
        logger.log("auto-backup prefs: applied on pairing knownDesktop=\(knownDesktop) requested=\(prefs.requested()) enabled=\(prefs.enabled())")
        return false
    } catch {
        logger.log("auto-backup prefs: apply on pairing failed (knownDesktop=\(knownDesktop)): \(error)")
        return !knownDesktop
    }
}

final class LiveEngineAdapter: BackupEngine, @unchecked Sendable {
    private let backend: LiveBackend
    private let lock = NSLock()
    private var latest = FlowFacts()
    private var latestRefresh: BackgroundRefreshAvailability = .available

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
            let r = await backend.engineModel.backgroundRefresh
            lock.lock(); latest = f; latestRefresh = r; lock.unlock()
            await MainActor.run { self.listeners.forEach { $0() } }
        }
    }

    @MainActor private var listeners: [() -> Void] = []

    func facts() -> FlowFacts { lock.lock(); defer { lock.unlock() }; return latest }
    func backgroundRefresh() -> BackgroundRefreshAvailability { lock.lock(); defer { lock.unlock() }; return latestRefresh }

    func observe(_ onChange: @escaping () -> Void) {
        Task { @MainActor in self.listeners.append(onChange) }
    }

    func pauseOrResume() async {
        let view = await backend.engine.view
        if view.state == .paused { _ = await backend.engine.resume() } else { _ = await backend.engine.pause() }
        await backend.refreshFacts()
    }

    func autoBackup() -> Bool { backend.autoPrefs.enabled() }
    func setAutoBackup(_ on: Bool) throws {
        do {
            try backend.autoPrefs.setUserChoice(on)
            backend.logger.log("auto-backup prefs: saved on=\(on)")
        } catch {
            backend.logger.log("auto-backup prefs: write failed (on=\(on)): \(error)")
            throw error
        }
        Task { await backend.refreshFacts() } // 只改策略，不凭空起一轮（Android 同：开关只存偏好）
    }

    /// 用户命令（#972）：失败记日志后抛给界面；成功与否都先刷新首页事实再返回。「状态不允许」是返回值（nil），不是错误。
    private func command<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            backend.logger.log("command \(name) ok")
            await backend.refreshFacts()
            return result
        } catch {
            backend.logger.log("command \(name) failed: \(error)")
            await backend.refreshFacts()
            throw error
        }
    }

    func remainingSnapshot() async throws -> RemainingSnapshot {
        try await command("remainingSnapshot") { try await backend.engine.remainingSnapshot() }
    }

    func cancelRemaining(_ snapshot: RemainingSnapshot) async throws -> Int? {
        try await command("cancelRemaining") { try await backend.engine.cancelRemaining(snapshot) }
    }

    func restoreSkipped() async throws {
        _ = try await command("restoreSkipped") { try await backend.engine.restoreSkipped() }
    }

    func acknowledgeMissingSource() {
        Task { await backend.engine.acknowledgeMissingSource(); await backend.refreshFacts() }
    }

    func notifyOnFailure() -> Bool { backend.notifyPrefs.enabled() }
    func setNotifyOnFailure(_ on: Bool) throws {
        do { try backend.notifyPrefs.setEnabled(on); backend.logger.log("notify-prefs: saved enabled=\(on)") } catch {
            backend.logger.log("notify-prefs: write failed: \(error)")
            throw error
        }
    }

    private let lastLoggedAuth = NSLock()
    nonisolated(unsafe) private var loggedAuth: NotificationAuthorization?
    func notificationAuthorization() async -> NotificationAuthorization {
        let auth = await SystemNotifications.authorization()
        lastLoggedAuth.lock(); defer { lastLoggedAuth.unlock() }
        if loggedAuth != auth { loggedAuth = auth; backend.logger.log("notifications: system authorization=\(auth)") }
        return auth
    }
    func requestNotificationAuthorization() async -> NotificationAuthorization {
        let granted = await SystemNotifications.request()
        let now = await SystemNotifications.authorization()
        backend.logger.log("notifications: system prompt result granted=\(granted) status=\(now)")
        return now
    }
    @MainActor func openNotificationSettings() { SystemNotifications.openSettings() }

    /// 「连过这台电脑」落盘。
    func finishOnboarding() throws {
        guard let record = backend.pairingStore.load() else {
            backend.logger.log("onboarded: finish without a pairing; nothing to mark"); return
        }
        do {
            try backend.onboarded.markOnboarded(record.daemonNodeId)
            backend.logger.log("onboarded: marked desktop=\(LogRedact.id(record.daemonNodeId)) at finish")
        } catch {
            backend.logger.log("onboarded: mark failed: \(error)")
            throw error
        }
    }

    func wifiOnly() -> Bool { backend.settings.wifiOnly() }
    func setWifiOnly(_ on: Bool) throws {
        do { try backend.settings.save(wifiOnly: on); backend.logger.log("backup-settings: saved wifiOnly=\(on)") } catch {
            backend.logger.log("backup-settings: write failed (wifiOnly=\(on)): \(error)")
            throw error
        }
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

    func retryFailed() async throws {
        _ = try await command("retryFailed") { try await backend.engine.retryFailed() }
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
/// 四项各接真逻辑：provider 撤销、取消 BGTask 唤醒（长任务 + 短任务）、注销相册监听、清缩略图内存缓存（#1119）。
struct DisconnectActions: DisconnectRuntime {
    let stopFlow: () -> Void
    let cancelWakes: () -> Void
    let stopMedia: () -> Void
    let clearThumbs: () -> Void
    func stopFlowRuntime() { stopFlow() }
    func cancelScheduledWakes() { cancelWakes() }
    func stopMediaChangeObserver() { stopMedia() }
    func clearThumbnailMemoryCache() { clearThumbs() }
}
