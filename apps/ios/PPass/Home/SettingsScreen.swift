import PPassCore
import SwiftUI

/// 「设置」tab（对位 Android HomeScreen.kt）：英雄卡 → 进度 / 状态行 → 红卡 → 设置卡。
/// 所有「说什么、什么颜色」都由 HomeProjection 的纯函数裁决，这里只做映射。
struct SettingsScreen: View {
    @EnvironmentObject var app: AppModel
    @Binding var tabBarHidden: Bool
    @State private var path: [Route] = []
    @State private var showDetails = false

    enum Route: Hashable { case bucket, storage, diagnostics }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard()
                    if let free = app.facts.view?.desktopFreeBytes, free < DesktopHealth.lowSpaceBytes {
                        Text(L.s("desktop_low_space_hint")).font(PPFont.body).foregroundStyle(PPColor.waiting)
                    }
                    // #343：iOS 能承诺什么、不能承诺什么（BackupPromise），常驻，不给「知道了」。
                    if let title = app.promise.first {
                        PPCard(fill: PPColor.paper, stroke: PPColor.borderStrong) {
                            Text(title).font(PPFont.sans(17, .bold))
                            ForEach(app.promise.dropFirst(), id: \.self) { line in
                                Text(line).font(PPFont.sans(15)).foregroundStyle(PPColor.ink60)
                            }
                        }
                    }
                    if app.pairingLost {
                        PPCard(fill: PPColor.actBg, stroke: PPColor.act.opacity(0.3)) {
                            Text(L.s("pairing_lost_title")).font(PPFont.serif(24)).foregroundStyle(PPColor.act)
                            Text(L.s("pairing_lost_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                            PPButton(title: L.s("reconnect"), kind: .danger) { app.startOver() }
                        }
                    } else if case .trouble(let detail) = app.uiState {
                        PPCard(fill: PPColor.actBg, stroke: PPColor.act.opacity(0.3)) {
                            Text(L.s("state_trouble")).font(PPFont.serif(24)).foregroundStyle(PPColor.act)
                            Text(L.s("run_failed")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                            Button(L.s(showDetails ? "trouble_details_hide" : "trouble_details_show")) { showDetails.toggle() }
                                .font(PPFont.sans(15)).foregroundStyle(PPColor.ink60)
                            if showDetails { Text(detail).font(.system(size: 13, design: .monospaced)).foregroundStyle(PPColor.ink40) }
                            PPButton(title: L.s("try_again"), kind: .danger) { app.retry() }
                        }
                    }
                    settingsCard
                }
                .padding(16)
            }
            .ppScreen()
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

    private var settingsCard: some View {
        VStack(spacing: 0) {
            row(L.s("backup_scope"), value: scopeValue) { path.append(.bucket) }
            Divider().overlay(PPColor.divider)
            row(L.s("storage_computer"), value: app.desktopName ?? L.s("storage_device_default")) { path.append(.storage) }
            Divider().overlay(PPColor.divider)
            row(L.s("setting_version"), value: AppVersion.current.displayLine) { path.append(.diagnostics) }
        }
        .background(PPColor.linen, in: RoundedRectangle(cornerRadius: PPRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PPRadius.card).stroke(PPColor.border, lineWidth: 1))
    }

    /// 「备份哪些相册」：只数已选且现存的（Android #541 / #836 同口径），0 或从未保存 → 「未选相册」。
    private var scopeValue: String {
        let n = app.scope?.count ?? 0
        return n > 0 ? L.p("backup_scope_n", n) : L.s("backup_scope_none")
    }

    private func row(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(PPFont.body).foregroundStyle(PPColor.ink)
                Spacer()
                Text(value).font(PPFont.sans(15)).foregroundStyle(PPColor.ink40).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(PPColor.ink40)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: PPSize.tapMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
