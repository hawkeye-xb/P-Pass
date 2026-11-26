import PhotosUI
import SwiftUI

enum LaunchRoute: String {
    case photos, family, settings, viewer, video, bucket, storage, diagnostics, about
    case decision
    case welcome, scan, manual, pairWaiting, pairCode, pairRefused, pairLapsed, pairFailed

    static let current: LaunchRoute? = {
        DebugLaunchInput.route.flatMap(LaunchRoute.init(rawValue:))
    }()
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            switch app.phase {
            case .onboarding:
                OnboardingFlow()
            case .decision:
                DecisionScreen()
            case .chooseAlbums:
                NavigationStack {
                    BucketScreen(firstTime: true) { selected, known, wantsAll in
                        app.albumsChosen(selected, known: known, wantsAll: wantsAll, firstTime: true)
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button { app.leaveFirstScope() } label: { Label(L.s("back"), systemImage: "chevron.backward") }
                                .accessibilityIdentifier("firstScopeBack")
                        }
                    }
                }
            case .main:
                MainTabs()
            }
        }
        .tint(PPColor.ink)
        .font(PPFont.body)
        .ppScreen()
        .onAppear(perform: applyLaunchRoute)
        .sheet(isPresented: $app.pickerRequested) {
            PhotoPickerSheet { results in
                app.pickedChosen(results.enumerated().compactMap { i, r in
                    PHPickedPayload.describe(r.itemProvider, index: i).map { (fileName: $0.name, mimeType: $0.mime, payload: $0.payload) }
                })
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $app.filePickerRequested) {
            SingleTransferFilePicker { items in app.pickedChosen(items) }
        }
        .alert(L.s("notice_title"), isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button(L.s("ok_got_it")) {}
        } message: { Text(app.notice?.message ?? "") }
    }

    private func applyLaunchRoute() {
        switch LaunchRoute.current {
        case .settings, .bucket, .storage, .diagnostics, .about: app.tab = .settings
        case .welcome, .scan, .manual, .pairWaiting, .pairCode, .pairRefused, .pairLapsed, .pairFailed: app.phase = .onboarding
        case .decision: app.phase = .decision
        default: break
        }
    }
}

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
                .badge(app.settingsAlert ? "!" : nil)
                .tag(AppModel.Tab.settings)
        }
    }
}
