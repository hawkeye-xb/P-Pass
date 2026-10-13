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
                        Label(L.s("desktop_low_space_hint"), systemImage: "externaldrive.badge.exclamationmark")
                            .font(.body).foregroundStyle(PPTone.waiting)
                    }
                }
                // #343：iOS 能承诺什么、不能承诺什么（BackupPromise），常驻，不给「知道了」。
                if let title = app.promise.first {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(title, systemImage: "info.circle").font(.body.weight(.semibold))
                            ForEach(app.promise.dropFirst(), id: \.self) { line in
                                Text(line).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if app.pairingLost {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L.s("pairing_lost_title"), systemImage: "exclamationmark.triangle.fill")
                                .font(.title3.bold()).foregroundStyle(PPTone.act)
                            Text(L.s("pairing_lost_body")).font(.body).foregroundStyle(.secondary)
                            PPButton(title: L.s("reconnect"), kind: .danger) { app.startOver() }
                        }
                        .padding(.vertical, 6)
                        .ppTinted(PPTone.act)
                    }
                } else if case .trouble(let detail) = app.uiState {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L.s("state_trouble"), systemImage: "exclamationmark.triangle.fill")
                                .font(.title3.bold()).foregroundStyle(PPTone.act)
                            Text(L.s("run_failed")).font(.body).foregroundStyle(.secondary)
                            Button(L.s(showDetails ? "trouble_details_hide" : "trouble_details_show")) { showDetails.toggle() }
                                .font(.subheadline).buttonStyle(.borderless)
                            if showDetails { Text(detail).font(.footnote.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled) }
                            PPButton(title: L.s("try_again"), kind: .danger) { app.retry() }
                        }
                        .padding(.vertical, 6)
                        .ppTinted(PPTone.act)
                    }
                }
                settingsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L.s("tab_settings"))
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

    private var settingsSection: some View {
        Section {
            row(L.s("backup_scope"), value: scopeValue, symbol: "photo.stack", route: .bucket)
            row(L.s("storage_computer"), value: app.desktopName ?? L.s("storage_device_default"), symbol: "desktopcomputer", route: .storage)
            row(L.s("setting_version"), value: AppVersion.current.displayLine, symbol: "info.circle", route: .diagnostics)
        }
    }

    /// 「备份哪些相册」：只数已选且现存的（Android #541 / #836 同口径），0 或从未保存 → 「未选相册」。
    private var scopeValue: String {
        let n = app.scope?.count ?? 0
        return n > 0 ? L.p("backup_scope_n", n) : L.s("backup_scope_none")
    }

    /// 系统导航行：图标 + 标题 + 次级值 + 系统 chevron（NavigationLink 自带）。
    private func row(_ title: String, value: String, symbol: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Label(title, systemImage: symbol).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }
}
