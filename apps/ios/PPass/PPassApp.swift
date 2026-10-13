import SwiftUI
import UIKit

@main
struct PPassApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let boot = AppBoot.make()

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot {
                case .ready(let model, _): RootView().environmentObject(model)
                case .failed(let message): StartupFailureView(message: message)
                }
            }
            // 系统默认 tint 是蓝色：根上统一换成墨色，按钮 / 开关 / 进度条不会冒出库色（#344）。
            .tint(PPColor.ink)
        }
        .onChange(of: scenePhase) { phase in
            guard case .ready(let model, let live) = boot else { return }
            live?.scenePhase(phase)
            if phase == .active { model.refresh() }
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
        do {
            let live = try LiveBackend()
            BatteryState.shared.start()
            let model = AppModel(backend: live.ports())
            live.start()
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
            endFinishing(expired: false)
            backend.setActive(true)
        case .background:
            backend.setActive(false)
            guard finishing == .invalid else { return }
            backend.window.setFinishingTime(true)
            finishing = UIApplication.shared.beginBackgroundTask(withName: "ppass.finish") { [weak self] in
                Task { @MainActor in self?.endFinishing(expired: true) }
            }
        default:
            break
        }
    }

    private func endFinishing(expired: Bool) {
        guard finishing != .invalid else { return }
        backend.window.setFinishingTime(false)
        if expired { Task { await backend.engine.onLeaseExpired() } }
        UIApplication.shared.endBackgroundTask(finishing)
        finishing = .invalid
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.s("state_trouble")).font(PPFont.serif(32)).foregroundStyle(PPColor.act)
            Text(L.s("run_failed")).font(PPFont.body).foregroundStyle(PPColor.ink60)
            Text(message).font(.system(size: 13, design: .monospaced)).foregroundStyle(PPColor.ink40).textSelection(.enabled)
            Spacer()
        }
        .padding(24)
        .ppScreen()
    }
}
