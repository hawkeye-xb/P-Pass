import SwiftUI

/// 截图 / 调试用的起始路由：环境变量 `PPASS_ROUTE`（simctl launch 时用 SIMCTL_CHILD_PPASS_ROUTE 传入）。
/// 只决定「一打开停在哪一屏」，不改任何业务数据。
enum LaunchRoute: String {
    case photos, settings, viewer, video, bucket, storage, diagnostics
    case welcome, scan, manual, pairWaiting, pairRefused, pairLapsed, pairFailed, backupStarted

    static let current: LaunchRoute? = {
        let raw = ProcessInfo.processInfo.environment["PPASS_ROUTE"] ?? UserDefaults.standard.string(forKey: "PPASS_ROUTE")
        return raw.flatMap(LaunchRoute.init(rawValue:))
    }()
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            switch app.phase {
            case .onboarding:
                OnboardingFlow()
            case .chooseAlbums:
                BucketScreen(firstTime: true) { selected, known in
                    app.albumsChosen(selected, known: known, firstTime: true)
                }
            case .backupStarted(let count):
                BackupStartedScreen(count: count) { app.phase = .main }
            case .main:
                MainTabs()
            }
        }
        .tint(PPColor.ink)
        .foregroundStyle(PPColor.ink)
        .onAppear(perform: applyLaunchRoute)
    }

    private func applyLaunchRoute() {
        switch LaunchRoute.current {
        case .settings, .bucket, .storage, .diagnostics: app.tab = .settings
        case .welcome, .scan, .manual, .pairWaiting, .pairRefused, .pairLapsed, .pairFailed: app.phase = .onboarding
        case .backupStarted: app.phase = .backupStarted(count: app.facts.inScopeTotal ?? 0)
        default: break
        }
    }
}

/// 两个 tab：照片 / 设置（Android TwoTabs.kt：默认照片；选中墨色加粗、顶上一条 2pt 墨线；
/// 看大图时整条 tab 栏不渲染）。用自绘的栏而不是系统 TabView：颜色与字号要走 token，
/// 系统栏的选中色与图标渲染不受 token 约束。
struct MainTabs: View {
    @EnvironmentObject var app: AppModel
    @State private var tabBarHidden = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PhotosScreen(tabBarHidden: $tabBarHidden).opacity(app.tab == .photos ? 1 : 0)
                    .allowsHitTesting(app.tab == .photos)
                SettingsScreen(tabBarHidden: $tabBarHidden).opacity(app.tab == .settings ? 1 : 0)
                    .allowsHitTesting(app.tab == .settings)
            }
            if !tabBarHidden {
                HStack(spacing: 0) {
                    tabButton(.photos, title: L.s("tab_photos"), icon: "camera")
                    tabButton(.settings, title: L.s("tab_settings"), icon: "gearshape", alert: settingsAlert)
                }
                .background(PPColor.paper.ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) { Rectangle().fill(PPColor.divider).frame(height: 1) }
            }
        }
        .ppScreen()
    }

    /// 设置 tab 的红点：配对失效（Android 另有后台被停两项，iOS 本轮不做后台）。
    private var settingsAlert: Bool { app.pairingLost }

    private func tabButton(_ tab: AppModel.Tab, title: String, icon: String, alert: Bool = false) -> some View {
        let selected = app.tab == tab
        return Button { app.tab = tab } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: selected ? "\(icon).fill" : icon).font(.system(size: 22))
                    if alert { Circle().fill(PPColor.act).frame(width: 9, height: 9).offset(x: 6, y: -2) }
                }
                Text(title).font(PPFont.sans(15, selected ? .bold : .regular))
            }
            .foregroundStyle(selected ? PPColor.ink : PPColor.ink40)
            .frame(maxWidth: .infinity, minHeight: PPSize.tapMin)
            .overlay(alignment: .top) { if selected { Rectangle().fill(PPColor.ink).frame(height: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
