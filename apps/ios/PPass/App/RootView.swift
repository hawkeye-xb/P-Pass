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
                NavigationStack {
                    BucketScreen(firstTime: true) { selected, known in
                        app.albumsChosen(selected, known: known, firstTime: true)
                    }
                }
            case .backupStarted(let count):
                BackupStartedScreen(count: count, asksNotification: app.asksNotificationAtOnboarding) { app.finishOnboardingStarted() }
            case .main:
                MainTabs()
            }
        }
        .tint(PPColor.ink)
        .font(PPFont.body)
        .ppScreen()
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

/// 两个 tab：照片 / 设置（Android TwoTabs.kt：默认照片）。iOS 用系统 TabView + SF Symbols，
/// 选中色由根上的 `.tint`（品牌 accent）决定；设置 tab 的红点换成系统角标。
/// 看大图是 fullScreenCover，自然盖住 tab 栏，不需要手动隐藏。
struct MainTabs: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView(selection: $app.tab) {
            PhotosScreen()
                .toolbarBackground(PPColor.paper, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
                .tabItem { Label(L.s("tab_photos"), systemImage: "photo.on.rectangle") }
                .tag(AppModel.Tab.photos)
            SettingsScreen()
                .toolbarBackground(PPColor.paper, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
                .tabItem { Label(L.s("tab_settings"), systemImage: "gearshape") }
                .badge(settingsAlert ? "!" : nil)
                .tag(AppModel.Tab.settings)
        }
    }

    /// 设置 tab 的角标：配对失效（Android 另有后台被停两项，iOS 本轮不做后台）。
    private var settingsAlert: Bool { app.pairingLost }
}
