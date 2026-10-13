import PPassCore
import SwiftUI

/// 「设置」tab（对位 Android HomeScreen.kt）：英雄卡 → 进度 / 状态行 → 红卡 → 设置卡。
/// 所有「说什么、什么颜色」都由 HomeProjection 的纯函数裁决，这里只做映射。
struct SettingsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var path: [Route] = []
    @State private var showDetails = false

    enum Route: Hashable { case bucket, storage, diagnostics }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                HeroCard()
                if let free = app.facts.view?.desktopFreeBytes, free < DesktopHealth.lowSpaceBytes {
                    Section {
                        Text(L.s("desktop_low_space_hint"))
                            .font(PPFont.body).foregroundStyle(PPColor.waiting)
                    }
                }
                if app.pairingLost {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.s("pairing_lost_title"))
                                .font(PPFont.title3).foregroundStyle(PPColor.act)
                            Text(L.s("pairing_lost_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                            PPButton(title: L.s("reconnect"), kind: .danger) { app.startOver() }
                        }
                        .padding(.vertical, 6)
                        .ppTinted(PPColor.actBg)
                    }
                } else if case .trouble(let detail) = app.uiState {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.s("state_trouble"))
                                .font(PPFont.title3).foregroundStyle(PPColor.act)
                            Text(L.s("run_failed")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                            Button(L.s(showDetails ? "trouble_details_hide" : "trouble_details_show")) { showDetails.toggle() }
                                .font(PPFont.subheadline).buttonStyle(.borderless)
                            if showDetails { Text(detail).font(PPFont.monoSmall).foregroundStyle(PPColor.ink40).textSelection(.enabled) }
                            PPButton(title: L.s("try_again"), kind: .danger) { app.retry() }
                        }
                        .padding(.vertical, 6)
                        .ppTinted(PPColor.actBg)
                    }
                }
                settingsSection
            }
            .listStyle(.insetGrouped)
            .ppList()
            .toolbar(.hidden, for: .navigationBar) // 同 Android：无页标题
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .bucket:
                    BucketScreen(firstTime: false) { selected, known in
                        app.albumsChosen(selected, known: known, firstTime: false)
                        path.removeAll()
                    }
                case .storage: StorageDetailScreen()
                case .diagnostics: DiagnosticsScreen()
                }
            }
        }
        .onAppear {
            switch LaunchRoute.current {
            case .bucket: path = [.bucket]
            case .storage: path = [.storage]
            case .diagnostics: path = [.diagnostics]
            default: break
            }
        }
    }

    /// 同 Android 两组：备份规则（范围 + 开关）｜关于（存储电脑 + 版本）。无图标、无组标签。
    @ViewBuilder private var settingsSection: some View {
        Section {
            row(L.s("backup_scope"), value: scopeValue, route: .bucket)
            Toggle(L.s("auto_backup_pause"), isOn: Binding(get: { app.autoBackup }, set: { app.setAutoBackup($0) }))
                .font(PPFont.body).tint(PPColor.safe)
            Toggle(L.s("setting_wifi_only"), isOn: Binding(get: { app.wifiOnly }, set: { app.setWifiOnly($0) }))
                .font(PPFont.body).tint(PPColor.safe)
        }
        Section {
            row(L.s("storage_computer"), value: app.desktopName ?? L.s("storage_device_default"), route: .storage)
            row(L.s("setting_version"), value: AppVersion.current.displayLine, route: .diagnostics)
        }
    }

    /// 「备份哪些相册」：只数已选且现存的（Android #541 / #836 同口径），0 或从未保存 → 「未选相册」。
    private var scopeValue: String {
        let n = app.scope?.count ?? 0
        return n > 0 ? L.p("backup_scope_n", n) : L.s("backup_scope_none")
    }

    /// 系统导航行：图标 + 标题 + 次级值 + 系统 chevron（NavigationLink 自带）。
    private func row(_ title: String, value: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Text(title).font(PPFont.body).foregroundStyle(PPColor.ink)
                Spacer(minLength: 8)
                Text(value).font(PPFont.subheadline).foregroundStyle(PPColor.ink40).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }
}
