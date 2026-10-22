import PPassCore
import SwiftUI

/// 「设置」tab（对位 Android HomeScreen.kt）：英雄卡 → 进度 / 状态行 → 红卡 → 设置卡。
/// 所有「说什么、什么颜色」都由 HomeProjection 的纯函数裁决，这里只做映射。
struct SettingsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var path: [Route] = []
    @State private var showDetails = false
    @State private var cancelSnapshot: RemainingSnapshot?
    @State private var asking = false

    enum Route: Hashable { case bucket, storage, diagnostics }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                HeroCard()
                // 后台刷新告示（对位 Android NoticeHost BACKUP_INTERRUPTED）。只放设置页、作为列表里的一行，不盖英雄卡；
                // 照片页只靠设置 tab 的角标提醒（照片页是浏览用的，顶部不占）。不给「知道了」：事实还在就一直说。
                if let n = app.backgroundNotice {
                    Section {
                        // 布局对位 Android NoticeCard：一行正文 + 右侧加粗下划线的动作。
                        HStack(alignment: .center, spacing: 12) {
                            Text(n.body).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if n.canResolve {
                                Button(L.s("background_backup_notice_action")) { app.openAppSettings() }
                                    .font(PPFont.subheadlineBold).underline().foregroundStyle(PPColor.ink)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("backgroundNoticeAction")
                            }
                        }
                        // 内边距照 Android NoticeCard 的 padding(16, 13)：直接设这一行的 insets，不在系统行距上再叠一层。
                        .listRowInsets(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
                        .ppTinted(PPColor.waitingBg)
                        .accessibilityIdentifier("backgroundNotice")
                    }
                }
                if app.facts.missingSourceUnacknowledged > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.p("missing_source_notice_body", Int(app.facts.missingSourceUnacknowledged)))
                                .font(PPFont.body).foregroundStyle(PPColor.ink60)
                            // 出路是「知道了」，不是重传：源已经不在手机上，没有任何动作能把它变回来。
                            Button(L.s("missing_source_notice_dismiss")) { app.acknowledgeMissingSource() }
                                .font(PPFont.subheadlineBold).buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .ppTinted(PPColor.waitingBg)
                    }
                }
                if app.pairingLost {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.s("pairing_lost_title"))
                                .font(PPFont.cardTitle).foregroundStyle(PPColor.act)
                            Text(L.s("pairing_lost_body")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                            // 同 Android：出路按钮是 ink 主按钮；红色只在标题上表示「需要处理」。
                            PPButton(title: L.s("reconnect")) { app.startOver() }
                        }
                        .padding(.vertical, 6)
                        .ppTinted(PPColor.actBg)
                    }
                } else if case .trouble(let detail) = app.uiState {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.s("state_trouble"))
                                .font(PPFont.cardTitle).foregroundStyle(PPColor.act)
                            Text(L.s("run_failed")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                            Button(L.s(showDetails ? "trouble_details_hide" : "trouble_details_show")) { showDetails.toggle() }
                                .font(PPFont.sans(PPUI.TextSize.detailToggle, .bold, relativeTo: .footnote)).underline()
                                .foregroundStyle(PPColor.ink40).buttonStyle(.borderless)
                            if showDetails { Text(detail).font(PPFont.monoSmall).foregroundStyle(PPColor.ink40).textSelection(.enabled) }
                            PPButton(title: L.s("try_again")) { app.retry() }
                        }
                        .padding(.vertical, 6)
                        .ppTinted(PPColor.actBg)
                    }
                }
                settingsSection
            }
            .listStyle(.insetGrouped)
            .ppList()
            .ppCardSpacing()
            .toolbar(.hidden, for: .navigationBar) // 同 Android：无页标题
            // 居中警告框（同「断开连接」：iOS 26 上 confirmationDialog 是贴着按钮的气泡）。关闭按钮叫「返回」不叫「取消」：
            // 要确认的动作本身就叫取消（Android #418 同）。
            .alert(cancelSnapshot.map { L.p("cancel_remaining_confirm_title", $0.count) } ?? "",
                   isPresented: $asking) {
                if let snap = cancelSnapshot {
                    Button(L.p("cancel_remaining_label", snap.count), role: .destructive) { app.cancelRemaining(snap) }
                }
                Button(L.s("back"), role: .cancel) {}
            } message: { Text(L.s("cancel_remaining_confirm_body")) }
            // 关「仅 Wi‑Fi」先确认（移动网络会消耗流量）；点「取消」开关不动、不写盘（Android MOB-02 §三，#982）。
            .alert(L.s("wifi_off_confirm_title"), isPresented: Binding(get: { app.pendingWifiOff }, set: { if !$0 { app.dismissWifiOffPrompt() } })) {
                Button(L.s("wifi_off_confirm_ok"), role: .destructive) { app.confirmWifiOff() }
                Button(L.s("cancel"), role: .cancel) { app.cancelWifiOff() }
            } message: { Text(L.s("wifi_off_confirm_body")) }
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
            if let n = app.cancelRemainingCount {
                Button {
                    Task {
                        // 弹窗里的 N 用点击这一刻的快照，不用行上的数（两者可能已差几张）。
                        if let snap = await app.remainingSnapshot() { cancelSnapshot = snap; asking = true }
                    }
                } label: {
                    Text(L.p("cancel_remaining_label", Int(n))).font(Self.labelFont).foregroundStyle(PPColor.ink)
                }
                .disabled(app.commandInFlight)
            }
            if app.facts.skippedByUser > 0 {
                Button { app.restoreSkipped() } label: {
                    HStack {
                        Text(L.s("cancelled_round_cell_label")).font(Self.labelFont).foregroundStyle(PPColor.ink)
                        Spacer(minLength: 8)
                        Text(L.p("cancelled_round_cell_value", Int(app.facts.skippedByUser))).font(Self.valueFont).foregroundStyle(PPColor.ink40)
                    }
                }
                .disabled(app.commandInFlight)
            }
            if app.facts.missingSourceAcknowledged > 0 {
                HStack {
                    Text(L.s("missing_source_archive_label")).font(Self.labelFont)
                    Spacer(minLength: 8)
                    Text(L.p("missing_source_archive_value", Int(app.facts.missingSourceAcknowledged))).font(Self.valueFont).foregroundStyle(PPColor.ink40)
                }
            }
            Toggle(L.s("auto_backup_pause"), isOn: Binding(get: { app.autoBackup }, set: { app.setAutoBackup($0) }))
                .font(Self.labelFont).tint(PPColor.safe)
            Toggle(L.s("setting_wifi_only"), isOn: Binding(get: { app.wifiOnly }, set: { app.setWifiOnly($0) }))
                .font(Self.labelFont).tint(PPColor.safe)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L.s("rule_notify"), isOn: Binding(get: { app.notifyToggleOn }, set: { app.setNotifyToggle($0) }))
                    .font(Self.labelFont).tint(PPColor.safe)
                Text(L.s("rule_notify_hint")).font(Self.hintFont).foregroundStyle(PPColor.ink40)
                if app.notificationAuthorization == .denied {
                    // iOS 系统框只弹一次，被拒之后只能去系统设置打开（06-ios-variants）。
                    Text(L.s("rule_notify_denied_hint")).font(Self.hintFont).foregroundStyle(PPColor.ink40)
                }
            }
        }
        .ppTinted(PPUI.Surface.settingsCard)
        Section {
            row(L.s("storage_computer"), value: app.desktopName ?? L.s("storage_device_default"), route: .storage)
            row(L.s("setting_version"), value: AppVersion.current.displayLine, route: .diagnostics)
        }
        .ppTinted(PPUI.Surface.settingsCard)
    }

    // 设置行字号：tokens.json mobile-ui.type（iOS 覆盖为系统文字样式，见 platforms.ios）。
    private static let labelFont = PPFont.sans(PPUI.TextSize.rowLabel)
    private static let valueFont = PPFont.sans(PPUI.TextSize.rowValue, relativeTo: .subheadline)
    private static let hintFont = PPFont.sans(PPUI.TextSize.rowHint, relativeTo: .footnote)

    /// 「备份哪些相册」：只数已选且现存的（Android #541 / #836 同口径），0 或从未保存 → 「未选相册」。
    private var scopeValue: String {
        if app.scopeUnreadable { return L.s("backup_scope_unreadable") }
        let n = app.selectedAlbumCount ?? 0
        return n > 0 ? L.p("backup_scope_n", n) : L.s("backup_scope_none")
    }

    /// 系统导航行：图标 + 标题 + 次级值 + 系统 chevron（NavigationLink 自带）。
    private func row(_ title: String, value: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Text(title).font(Self.labelFont).foregroundStyle(PPColor.ink)
                Spacer(minLength: 8)
                Text(value).font(Self.valueFont).foregroundStyle(PPColor.ink40).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }
}
