import PPassBackgroundTasks
import PPassCore
import SwiftUI
import UIKit

@main
struct PPassApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// 在 App init 里建：后台任务的 handler 必须在启动完成前注册（AppBoot.init 里注册）。
    private let boot = AppBoot()

    init() {
        PPAppearance.install()
        ForegroundNotificationPresenter.install() // #1018：前台发出的通知也要展示，须在启动早期设代理
    }

    var body: some Scene {
        WindowGroup {
            BootView(boot: boot)
                // 系统默认 tint 是蓝色：根上统一换成品牌 accent（墨 / 深色下为纸），控件不会冒出库色（#344 / #943）。
                .tint(PPColor.ink)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { boot.retryIfWaitingForUnlock() }
            guard case .ready(let model, let live) = boot.state else { return }
            live?.scenePhase(phase)
            if phase == .active { model.sceneBecameActive() }
        }
    }
}

private struct BootView: View {
    @ObservedObject var boot: AppBoot

    var body: some View {
        switch boot.state {
        case .ready(let model, _): RootView().environmentObject(model)
        case .waitingForUnlock: PPColor.paper.ignoresSafeArea()
        case .identityUnavailable(_, let resetFailed):
            IdentityUnavailableView(resetFailed: resetFailed,
                                    onRetry: { boot.retry() }, onReset: { boot.resetIdentityAndRetry() })
        case .failed(let message): StartupFailureView(message: message)
        }
    }
}

/// 选哪套端口实现（#925）。默认真实现；宿主 XCTest 与显式要演示场景时（截图、调试）用演示数据。
/// 真实现起不来时如实显示，不悄悄退回演示数据：
/// - 开机后还没解锁过（钥匙串里的身份读不到）→ 等：受保护数据可用 / 回到前台时再起一次，不算故障；
/// - 钥匙串故障 → 拒绝启动页（重试 / 重置并重新配对），不回退、不悄悄换身份；
/// - 其余（存储根 / provider 打不开）→ 错误页。
@MainActor
final class AppBoot: ObservableObject {
    enum State {
        case ready(AppModel, LiveLifecycle?)
        case waitingForUnlock
        /// [resetFailed]：用户点了「重置并重新配对」也没成（文案换成重置失败的说明）。
        case identityUnavailable(String, resetFailed: Bool)
        case failed(String)
    }

    @Published private(set) var state: State = .waitingForUnlock
    private let target = BackgroundTargetBox()
    private let logger = OSLogger()
    private var unlockObserver: NSObjectProtocol?

    init() {
        if Self.useDemo {
            state = .ready(AppModel(backend: FakeBackend.make()), nil)
            return
        }
        AppLog.logLaunch()
        #if DEBUG
        OriginalLocalityProbe.logTestFilesAtLaunch() // #337 / #1016 真机取证：只读、不下载
        // 仅 DEBUG：PPASS_E2E_RESET=1 → 启动前清掉存储根（配对 / 账本 / provider 库）和钥匙串里的身份，等价于全新安装但保留系统授权。
        // 真机端到端每轮换一个新 daemon，旧账本会把「已确认」算给旧电脑，必须从空账本开始。
        if ProcessInfo.processInfo.environment["PPASS_E2E_RESET"] == "1",
           let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("PPass", isDirectory: true))
            try? KeychainIdentityStore().delete()
        }
        // 仅 DEBUG：PPASS_DEBUG_DROP_IDENTITY=1 → 只删钥匙串里的身份、存储根原样，等价于「备份恢复到新手机 / 钥匙串被清」：
        // 真机上验证「有配对、没私钥 → 新设备、清配对」，不用抹机恢复。
        if ProcessInfo.processInfo.environment["PPASS_DEBUG_DROP_IDENTITY"] == "1" {
            do { try KeychainIdentityStore().delete(); logger.log("boot: DEBUG dropped the identity key") } catch {
                logger.log("boot: DEBUG drop identity failed: \(error)")
            }
        }
        #endif
        // 不等 App 起来就注册：系统按 identifier 拉起进程而 handler 没注册会崩；没起来时 handler 直接交还系统。
        let target = self.target
        PPassBackgroundTasks.register(logger: logger, target: { target.get() })
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfWaitingForUnlock() }
        }
        state = build()
    }

    /// 开机后首次解锁：系统发 protectedDataDidBecomeAvailable；被预热拉起的进程挂着时可能收不到，回前台时也补一次。
    func retryIfWaitingForUnlock() {
        guard case .waitingForUnlock = state else { return }
        logger.log("boot: protected data available, starting again")
        state = build()
    }

    /// 拒绝启动页「重试」。
    func retry() { state = build() }

    /// 拒绝启动页「重置并重新配对」：换新私钥、清本地配对，再起一次（未配对 → 扫码）。
    func resetIdentityAndRetry() {
        do {
            try LiveBackend.resetIdentity()
            state = build()
        } catch {
            logger.log("boot: identity reset failed: \(error)")
            state = .identityUnavailable(String(describing: error), resetFailed: true)
        }
    }

    private func build() -> State {
        do {
            let live = try LiveBackend(identityStore: Self.identityStore)
            #if DEBUG
            // 真机验证用：私钥指纹（BLAKE3 前 8 位），比对两次启动是不是同一把；Release 不打。
            logger.log("identity: debug fingerprint \(live.identityFingerprint)")
            #endif
            LiveTimeline.clearShareDir() // 上次被杀 / 崩溃留下的原图残留
            BatteryState.shared.start()
            let model = AppModel(backend: live.ports())
            live.start()
            target.set(live.backgroundTarget())
            #if DEBUG
            if E2EDriver.requested { E2EDriver.run(model: model) }
            #endif
            return .ready(model, LiveLifecycle(backend: live))
        } catch IdentityStoreError.locked {
            logger.log("boot: keychain locked (device not unlocked since restart); waiting")
            return .waitingForUnlock
        } catch let error as IdentityStoreError {
            logger.log("boot: identity unavailable: \(error)")
            return .identityUnavailable(String(describing: error), resetFailed: false)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// 仅 DEBUG：PPASS_DEBUG_IDENTITY_FAIL=1 → 钥匙串读失败（看拒绝启动页用）。
    private static var identityStore: IdentitySecretStore {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PPASS_DEBUG_IDENTITY_FAIL"] == "1" { return FailingIdentityStore() }
        #endif
        return KeychainIdentityStore()
    }

    static var useDemo: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        #if DEBUG
        if env["PPASS_SCENARIO"] != nil || UserDefaults.standard.string(forKey: "PPASS_SCENARIO") != nil { return true }
        #endif
        return false
    }
}

#if DEBUG
private struct FailingIdentityStore: IdentitySecretStore {
    func read() throws -> Data? { throw IdentityStoreError.failed(op: "read", status: -25291) }
    func write(_ key: Data) throws { throw IdentityStoreError.failed(op: "write", status: -25291) }
    func delete() throws { throw IdentityStoreError.failed(op: "delete", status: -25291) }
}
#endif

/// 后台任务 handler 与 AppBoot 之间的那一格：App 起来之前是 nil。
final class BackgroundTargetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackgroundTarget?

    func get() -> BackgroundTarget? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ target: BackgroundTarget) {
        lock.lock(); value = target; lock.unlock()
    }
}

/// scenePhase → 执行窗口（#340 接线说明第 4 条）：前台 = 可以跑；进后台申请一段收尾时间，到期收回租约。
@MainActor
final class LiveLifecycle {
    private let backend: LiveBackend
    private var finishing: UIBackgroundTaskIdentifier = .invalid
    /// 真的在前台（没退到过 .background）。对位 Android 按 Activity started/stopped 计数、不按 resumed/paused：
    /// 下拉控制中心 / 通知中心、App 切换器拉一半又松手、系统权限框，都只是 .inactive → .active，不算「回到前台」，
    /// 不该每次都跑一遍带对账的前台补捞、重拍心跳。
    private var inForeground = false

    init(backend: LiveBackend) { self.backend = backend }

    func scenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard !inForeground else {
                backend.logger.log("scene: active again without leaving the foreground (inactive → active); no catch-up")
                return
            }
            inForeground = true
            LaunchOriginRecorder.shared.foregroundReached(logger: backend.logger)
            endFinishing(expired: false)
            backend.setActive(true)
        case .background:
            inForeground = false
            backend.setActive(false)
            PPassBackgroundTasks.ensureShortScheduled(logger: backend.logger)
            guard finishing == .invalid else { return }
            backend.window.setFinishingTime(true)
            // 系统在主线程上调 expiration handler，到期前必须结束后台任务，否则进程被杀（#1007）：
            // 在 handler 里同步关窗口、同步 endBackgroundTask，不排到 handler 返回之后。
            finishing = UIApplication.shared.beginBackgroundTask(withName: "ppass.finish") { [weak self] in
                MainActor.assumeIsolated { self?.endFinishing(expired: true) }
            }
        default:
            break
        }
    }

    private func endFinishing(expired: Bool) {
        guard finishing != .invalid else { return }
        backend.window.setFinishingTime(false)
        if expired {
            // 只关宽限期自己；停不停由引擎按此刻的租约定（前台 / 长任务 / 短任务还开着就不停这一轮）。
            let engine = backend.engine, window = backend.window
            Task { await BackgroundRun.expireFinishingTime(engine: engine, window: window) }
        }
        UIApplication.shared.endBackgroundTask(finishing)
        finishing = .invalid
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(PPColor.act)
                Text(L.s("state_trouble")).font(PPFont.largeTitle).foregroundStyle(PPColor.act)
                Text(L.s("run_failed")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                Text(message).font(PPFont.monoSmall).foregroundStyle(PPColor.ink40).textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PPColor.paper.ignoresSafeArea())
    }
}

/// 钥匙串里的身份读写失败（不是「开机后还没解锁过」）：不回退、不悄悄换身份，说明原因，给两条路。
/// 对位 Android #1106 `IdentityUnavailableScreen`（同一组文案 identity_*、同样的排版）；技术原因只进日志，不上屏。
struct IdentityUnavailableView: View {
    let resetFailed: Bool
    let onRetry: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text(L.s("identity_unavailable_title")).font(PPFont.title2).foregroundStyle(PPColor.ink)
            Text(L.s(resetFailed ? "identity_reset_failed_body" : "identity_unavailable_body"))
                .font(PPFont.body).foregroundStyle(PPColor.ink60).padding(.top, 14)
            PPButton(title: L.s("identity_unavailable_retry"), action: onRetry).padding(.top, 36)
            PPButton(title: L.s("identity_unavailable_reset"), kind: .quiet, height: 58, fontSize: 18, action: onReset).padding(.top, 12)
            Text(L.s("identity_unavailable_reset_hint")).font(PPFont.sans(14)).foregroundStyle(PPColor.ink40)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(34)
        .background(PPColor.paper.ignoresSafeArea())
    }
}
