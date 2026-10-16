import PPassBackgroundTasks
import PPassCore
import SwiftUI
import UIKit

@main
struct PPassApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let boot = AppBoot.make()

    init() { PPAppearance.install() }

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot {
                case .ready(let model, _): RootView().environmentObject(model)
                case .failed(let message): StartupFailureView(message: message)
                }
            }
            // 系统默认 tint 是蓝色：根上统一换成品牌 accent（墨 / 深色下为纸），控件不会冒出库色（#344 / #943）。
            .tint(PPColor.ink)
        }
        .onChange(of: scenePhase) { phase in
            guard case .ready(let model, let live) = boot else { return }
            live?.scenePhase(phase)
            if phase == .active { model.sceneBecameActive() }
        }
    }
}

/// 选哪套端口实现（#925）。默认真实现；宿主 XCTest 与显式要演示场景时（截图、调试）用演示数据。
/// 真实现起不来（存储根 / 身份 / provider 打不开）时如实显示错误页，不悄悄退回演示数据。
enum AppBoot {
    case ready(AppModel, LiveLifecycle?)
    case failed(String)

    @MainActor static func make() -> AppBoot {
        if useDemo { return .ready(AppModel(backend: FakeBackend.make()), nil) }
        AppLog.logLaunch()
        #if DEBUG
        // 仅 DEBUG：PPASS_E2E_RESET=1 → 启动前清掉存储根（配对 / 账本 / provider 库 / 身份），等价于全新安装但保留系统授权。
        // 真机端到端每轮换一个新 daemon，旧账本会把「已确认」算给旧电脑，必须从空账本开始。
        if ProcessInfo.processInfo.environment["PPASS_E2E_RESET"] == "1",
           let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("PPass", isDirectory: true))
        }
        #endif
        do {
            LiveTimeline.clearShareDir() // 上次被杀 / 崩溃留下的原图残留
            let live = try LiveBackend()
            BatteryState.shared.start()
            let model = AppModel(backend: live.ports())
            live.start()
            #if DEBUG
            if E2EDriver.requested { E2EDriver.run(model: model) }
            #endif
            return .ready(model, LiveLifecycle(backend: live))
        } catch {
            return .failed(String(describing: error))
        }
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

/// scenePhase → 执行窗口（#340 接线说明第 4 条）：前台 = 可以跑；进后台申请一段收尾时间，到期收回租约。
@MainActor
final class LiveLifecycle {
    private let backend: LiveBackend
    private var finishing: UIBackgroundTaskIdentifier = .invalid

    init(backend: LiveBackend) { self.backend = backend }

    func scenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            LaunchOriginRecorder.shared.foregroundReached(logger: backend.logger)
            endFinishing(expired: false)
            backend.setActive(true)
            backend.flushPendingUnpairs()
        case .background:
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
