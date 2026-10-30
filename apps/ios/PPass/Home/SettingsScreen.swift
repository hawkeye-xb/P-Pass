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
                // #1263：onboarding 不再问后台备份，改在首页引导。卡片一直显示，直到用户开启后台备份或点「不用了」。
                // 点「开启」只写意图（iOS 没有 App 内的后台授权框）；后台 App 刷新被关时由下面的告示指路。
                if app.showsBackgroundCard {
                    Section {
                        NoticeRow(text: L.s("background_backup_offer"),
                                  action: (L.s("background_backup_offer_action"), { app.enableBackgroundFromCard() }),
                                  close: (L.s("background_backup_offer_close"), { app.dismissBackgroundCard() }))
                            .accessibilityIdentifier("backgroundCard")
                    }
                }
                // 告示区（对位 Android NoticeCard 的「一行正文 + 右侧动作」）：iOS 用系统列表行承载，
                // 行高、内边距、圆角交给原生 insetGrouped，不再硬设 Android 的 16/13（硬设会被行高 52 撑开）。
                // 后台刷新告示（对位 NoticeHost BACKUP_INTERRUPTED）只放设置页：照片页是浏览用的，顶部不占（用户 2026-10-19 拍板）。
                // 不给「知道了」：事实还在就一直说。
                if let n = app.backgroundNotice {
                    Section {
                        NoticeRow(text: n.body,
                                  action: n.canResolve ? (L.s("background_refresh_notice_action"), { app.openAppSettings() }) : nil)
                            .accessibilityIdentifier("backgroundNotice")
                    }
                }
                // 源已删除（对位 Android HomeScreen 的 SOURCE_MISSING NoticeCard，不进 NoticeHost 优先级）：
                // 出路是「知道了」，不是重传——源已经不在手机上，没有任何动作能把它变回来。
                if app.facts.missingSourceUnacknowledged > 0 {
                    Section {
                        NoticeRow(text: L.p("missing_source_notice_body", Int(app.facts.missingSourceUnacknowledged)),
                                  dismiss: (L.s("missing_source_notice_dismiss"), { app.acknowledgeMissingSource() }))
                            .accessibilityIdentifier("missingSourceNotice")
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
                    BucketScreen(firstTime: false) { selected, known, wantsAll in
                        app.albumsChosen(selected, known: known, wantsAll: wantsAll, firstTime: false)
                        path.removeAll()
                    }
                case .storage: StorageDetailScreen()
                case .diagnostics: DiagnosticsScreen()
                }
            }
        }
        .onAppear { if app.wantsScopeEditor { app.wantsScopeEditor = false; path = [.bucket] } }
        .onChange(of: app.wantsScopeEditor) { wants in if wants { app.wantsScopeEditor = false; path = [.bucket] } }
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
                // 不放「配对失效、权限收回…时提醒你」这句说明（Android 有）：iOS 带说明的行会被撑高，开关名本身已够清楚。
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

    /// 「备份哪些照片」：只数已选且现存的（Android #541 / #836 同口径），0 或从未保存 → 「未选相册」；
    /// 有相册时带上时间档：「3 个相册 · 10月29日起的照片 / 含以前的照片」（#1263，同 Android `backup_scope_with_time`）。
    private var scopeValue: String {
        if app.scopeUnreadable { return L.s("backup_scope_unreadable") }
        let n = app.selectedAlbumCount ?? 0
        guard n > 0 else { return L.s("backup_scope_none") }
        return L.f("backup_scope_with_time", L.p("backup_scope_n", n), Self.timeLabel(app.since ?? .all, now: Date()))
    }

    /// 设置行时间档的说法，一律写日期（10-29 文案定稿，同 Android `scopeValueLabel`）：某天起 →「M月d日起的照片」；
    /// 全部 →「含以前的照片」。用 scope_value_*（英文比选项短）。
    static func timeLabel(_ since: BackupSince, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard case .since(let ms) = since else { return L.s("scope_value_all") }
        return L.f("scope_value_since", scopeDate(Date(timeIntervalSince1970: Double(ms) / 1000), calendar: calendar, locale: locale))
    }

    /// 「10月29日」/「Oct 29」：时间档里的日期（选项与设置行同一种写法）。
    static func scopeDate(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
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

/// 告示行：一行正文 + 右侧动作（对位 Android `NoticeCard`）。底色 waitingBg 是品牌语义色，按 tokens 走；
/// 行高与内边距用系统列表行。「知道了」比「去处理」弱一档（无下划线、ink40），同 Android 的主次区分。
private struct NoticeRow: View {
    let text: String
    var action: (String, () -> Void)? = nil
    var dismiss: (String, () -> Void)? = nil
    /// 右上角 ×（无障碍标签, 动作）：非空时版式换成「正文占满整行 + 动作另起一行 + 右上角 ×」，同 Android NoticeCard 的 closeLabel 版式。
    var close: (String, () -> Void)? = nil

    var body: some View {
        if let c = close {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(text).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: c.1) {
                        Image(systemName: "xmark").font(PPFont.subheadlineBold).foregroundStyle(PPColor.ink40)
                            // HIG 最小触控区 44pt；负边距让图标仍贴着右上角，不把正文往下挤。
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, -12).padding(.trailing, -12)
                    .accessibilityLabel(c.0)
                    .accessibilityIdentifier("noticeClose")
                }
                if let a = action {
                    Button(a.0, action: a.1)
                        .font(PPFont.subheadlineBold).underline().foregroundStyle(PPColor.ink)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("noticeAction")
                }
            }
            .ppTinted(PPColor.waitingBg)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(text).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let d = dismiss {
                Button(d.0, action: d.1)
                    .font(PPFont.sans(15, .medium, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("noticeDismiss")
            }
            if let a = action {
                Button(a.0, action: a.1)
                    .font(PPFont.subheadlineBold).underline().foregroundStyle(PPColor.ink)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("noticeAction")
            }
        }
        .ppTinted(PPColor.waitingBg)
    }
}
