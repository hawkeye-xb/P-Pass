import PPassCore
import PhotosUI
import SwiftUI

/// 「设置」tab（对位 Android HomeScreen.kt）：英雄卡 → 进度 / 状态行 → 红卡 → 设置卡。
/// 所有「说什么、什么颜色」都由 HomeProjection 的纯函数裁决，这里只做映射。
struct SettingsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var path: [Route] = []
    @State private var showDetails = false
    @State private var cancelSnapshot: RemainingSnapshot?
    @State private var asking = false
    /// #1789「从文件选择」：系统文件选择器的弹层（只发起选择，登记走 pickedChosen 的既有链路）。
    @State private var showFilePicker = false

    enum Route: Hashable { case bucket, storage, diagnostics, more }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                HeroCard()
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
            // #1789「从文件选择」：系统文件选择器；只返回选中的 URL，不登记目录授权（#1785 组件、本卡挂载）。
            // 选完走 pickedChosen 的既有链路（登记 → 引擎前台逐张传），取消（空结果）不建任务。
            .sheet(isPresented: $showFilePicker) {
                SingleTransferFilePicker { items in app.pickedChosen(items) }
            }
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
                        app.albumsChosen(selected, known: known, wantsAll: wantsAll, firstTime: false) {
                            path.removeAll()
                        }
                    }
                case .storage: StorageDetailScreen()
                case .diagnostics: DiagnosticsScreen()
                case .more: moreScreen
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

    /// #1784：设置按「自动备份 / 单次传输 / 传输条件与通知」固定分组，组序由
    /// SingleTransferStatusTests 锁死；条件行只在原组内显隐，分组不移动。真有问题时上方
    /// 的红卡与告示自然出现（「需要注意」），不在这里重复。组内不贴 section 标签——
    /// 组的第一行（自动备份开关 / 从相册选择 / 仅 Wi-Fi）就是这组的名字。
    /// #1889：产品负责人 2026-11-19 拍板，「更多」不再单独成组，并入「通知」所在的一组。
    @ViewBuilder private var settingsSection: some View {
        // ── #1789 固定分组 1/3「自动备份」：开关、范围与它的条件行（取消剩余 / 已跳过 / 源已删除账目）。
        Section {
            ruleRow
            if app.autoRule {
                row(L.s("backup_scope"), value: scopeValue, route: .bucket)
                // 「App 关着也传」（原「后台备份」）：只在自动备份开着时出现。
                Toggle(L.s("auto_backup_pause"), isOn: Binding(get: { app.autoBackup }, set: { app.setAutoBackup($0) }))
                    .font(Self.labelFont).tint(PPColor.safe)
            }
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
        }
        .ppTinted(PPUI.Surface.settingsCard)

        // ── #1789 固定分组 2/3「单次传输」：固定两行「从相册选择」「从文件选择」，
        // 两行只发起选择，不显示进度、结果或最近一批——状态只在英雄区出现（#1784）。
        Section {
            SingleTransferSelectionRow(title: L.s("pick_from_photos_label")) { app.pickerRequested = true }
                .accessibilityIdentifier("pickPhotosRow")
            SingleTransferSelectionRow(title: L.s("pick_from_files_label")) { showFilePicker = true }
                .accessibilityIdentifier("pickFilesRow")
        }
        .ppTinted(PPUI.Surface.settingsCard)

        // ── #1789 固定分组 3/3「传输条件与通知」：仅 Wi-Fi 与失败通知两个开关，
        // 以及并入本组的「更多」入口（#1889：产品负责人 2026-11-19 拍板，不再单独成组）。
        Section {
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
            // 「更多」点进去仍是原来的二级页（存储电脑、断开连接、版本、检查更新）。
            row(L.s("more_label"), value: "", route: .more)
        }
        .ppTinted(PPUI.Surface.settingsCard)
        // ── #1789 固定分组结束
    }

    /// 「更多」二级页：存储电脑详情（含断开连接）、版本（含检查更新）。
    private var moreScreen: some View {
        List {
            Section {
                // #1251：电脑名不放在这一行，点进去详情里看（与 Android 一致）。
                row(L.s("storage_computer"), value: "", route: .storage)
                row(L.s("setting_version"), value: AppVersion.current.displayLine, route: .diagnostics)
            }
            .ppTinted(PPUI.Surface.settingsCard)
        }
        .listStyle(.insetGrouped)
        .ppList()
        .navigationTitle(L.s("more_label"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 「自动备份」规则开关 + 下一行小字（被拒 / 有限访问已传一次 / 规则开着时权限被收回）。
    private var ruleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(L.s("auto_backup_rule_label"), isOn: Binding(get: { app.autoRule }, set: { app.setAutoRule($0) }))
                .font(Self.labelFont).tint(PPColor.safe)
                .accessibilityIdentifier("autoBackupRuleToggle")
            if let hint = app.ruleHint {
                Text(hint).font(Self.hintFont).foregroundStyle(PPColor.ink40)
            }
        }
    }

    // 设置行字号：tokens.json mobile-ui.type（iOS 覆盖为系统文字样式，见 platforms.ios）。
    private static let labelFont = PPFont.sans(PPUI.TextSize.rowLabel)
    private static let valueFont = PPFont.sans(PPUI.TextSize.rowValue, relativeTo: .subheadline)
    private static let hintFont = PPFont.sans(PPUI.TextSize.rowHint, relativeTo: .footnote)

    /// 「备份范围」行值（#1789，对位 Android 同一行）：相册与素材文件夹用「 + 」连在一行，文件夹不再单独占设置行；
    /// 旧版已登记目录（从未保存过范围）也按真实来源显示，不再误报「未选定自动备份范围」。
    /// 「3 个相册 + 素材文件夹 2 · 含以前的照片」；读不到说「读不到」，什么都没有说「未选定自动备份范围」。
    /// 静态纯函数：SettingsFeedbackTests 直接跑它判红。
    static func scopeValueText(unreadable: Bool, albumCount: Int?, folderCount: Int, since: BackupSince?,
                               now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if unreadable { return L.s("backup_scope_unreadable") }
        let albums = albumCount.flatMap { $0 > 0 ? L.p("backup_scope_n", $0) : nil }
        let folders = folderCount > 0 ? "\(L.s("folder_scope_noun")) \(folderCount)" : nil
        let sources = [albums, folders].compactMap { $0 }.joined(separator: " + ")
        guard !sources.isEmpty else { return L.s("backup_scope_none") }
        guard let since else { return sources }
        return L.f("backup_scope_with_time", sources, timeLabel(since, now: now, calendar: calendar, locale: locale))
    }

    private var scopeValue: String {
        Self.scopeValueText(unreadable: app.scopeUnreadable, albumCount: app.selectedAlbumCount,
                            folderCount: app.selectedFolderCount, since: app.since, now: Date())
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
struct NoticeRow: View {
    let text: String
    var action: (String, () -> Void)? = nil
    var dismiss: (String, () -> Void)? = nil
    /// ×（无障碍标签, 动作）：非空时换成一行版式「左正文、右动作与 ×」，同 Android NoticeCard 的 closeLabel 版式（C1）。
    var close: (String, () -> Void)? = nil
    /// 不在 List 里用（照片页引导位）：List 行的底色与圆角由 List 给，这里自己补同样的浅底圆角与左内边距。
    var standalone = false

    var body: some View {
        if let c = close {
            // C1（10-30 用户定版）：一行——左边正文、右边「开启」与 ×，都垂直居中；正文放不下只让正文折行。
            // standalone 的边距逐项对位 Android NoticeCard：行上下 2 + 正文上下 10、动作左右 8、× 48 点击区贴右边。
            HStack(alignment: .center, spacing: standalone ? 0 : 4) {
                Text(text).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, standalone ? 10 : 0)
                if let a = action {
                    Button(action: a.1) { Text(a.0).underline() }
                        .font(PPFont.subheadlineBold).foregroundStyle(PPColor.ink)
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .padding(.horizontal, standalone ? 8 : 0)
                        .accessibilityIdentifier("noticeAction")
                }
                Button(action: c.1) {
                    Image(systemName: "xmark").font(PPFont.subheadlineBold).foregroundStyle(PPColor.ink40)
                        // HIG 最小触控区 44pt；右侧负边距让图标贴近卡片边，不多占正文宽度。
                        .frame(width: standalone ? 48 : 44, height: standalone ? 48 : 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.trailing, standalone ? 0 : -12)
                .accessibilityLabel(c.0)
                .accessibilityIdentifier("noticeClose")
            }
            .padding(.leading, standalone ? 16 : 0).padding(.vertical, standalone ? 2 : 0)
            .background(standalone ? PPColor.waitingBg : .clear, in: RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous))
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
                Button(action: a.1) { Text(a.0).underline() }
                    .font(PPFont.subheadlineBold).foregroundStyle(PPColor.ink)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("noticeAction")
            }
        }
        .ppTinted(PPColor.waitingBg)
    }
}

/// #1272：系统照片选择器。`PHPickerConfiguration()` 不传 photoLibrary ⇒ 走进程外选择器，不需要照片权限；
/// `.current` 给原始表示（不把 HEIC 转成 JPEG），这样内容哈希与自动备份读到的原图一致，两条路径之间才能按哈希去重。
struct PhotoPickerSheet: UIViewControllerRepresentable {
    /// #1840：单次入口允许的类型（产品口径 2026-11-17：只允许图片与视频，不允许文件夹）。
    static let mediaFilter: PHPickerFilter = .any(of: [.images, .videos])

    let onPicked: ([PHPickerResult]) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 选择器的配置只在这里定，测试直接跑它，不必伪造 `UIViewControllerRepresentableContext`。
    static func configuration() -> PHPickerConfiguration {
        var config = PHPickerConfiguration()
        config.selectionLimit = PickedQueue.maxPick
        config.filter = mediaFilter
        config.preferredAssetRepresentationMode = .current
        return config
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: Self.configuration())
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerSheet
        init(_ parent: PhotoPickerSheet) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            if !results.isEmpty { parent.onPicked(results) }
        }
    }
}
