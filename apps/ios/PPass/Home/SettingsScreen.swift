import PPassCore
import PhotosUI
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var path: [Route] = []
    @State private var showDetails = false
    @State private var cancelSnapshot: RemainingSnapshot?
    @State private var asking = false
    @State private var showFilePicker = false

    enum Route: CaseIterable, Hashable { case bucket, storage, diagnostics, more, about }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                HeroCard()
                if let n = app.backgroundNotice {
                    Section {
                        NoticeRow(text: n.body,
                                  action: n.canResolve ? (L.s("background_refresh_notice_action"), { app.openAppSettings() }) : nil)
                            .accessibilityIdentifier("backgroundNotice")
                    }
                }
                if app.facts.missingSourceUnacknowledged > 0 {
                    Section {
                        NoticeRow(text: L.p("missing_source_notice_body", Int(app.facts.missingSourceUnacknowledged)),
                                  dismiss: (L.s("missing_source_notice_dismiss"), { app.acknowledgeMissingSource() }))
                            .accessibilityIdentifier("missingSourceNotice")
                    }
                }
                if app.connection.needsRepair {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.s("pairing_lost_title"))
                                .font(PPFont.cardTitle).foregroundStyle(PPColor.act)
                            Text(L.s("pairing_lost_body")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
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
            .sheet(isPresented: $showFilePicker) {
                SingleTransferFilePicker { items in app.pickedChosen(items) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert(cancelSnapshot.map { L.p("cancel_remaining_confirm_title", $0.count) } ?? "",
                   isPresented: $asking) {
                if let snap = cancelSnapshot {
                    Button(L.p("cancel_remaining_label", snap.count), role: .destructive) { app.cancelRemaining(snap) }
                }
                Button(L.s("back"), role: .cancel) {}
            } message: { Text(L.s("cancel_remaining_confirm_body")) }
            .alert(L.s("wifi_off_confirm_title"), isPresented: Binding(get: { app.pendingWifiOff }, set: { if !$0 { app.dismissWifiOffPrompt() } })) {
                Button(L.s("wifi_off_confirm_ok"), role: .destructive) { app.confirmWifiOff() }
                Button(L.s("cancel"), role: .cancel) { app.cancelWifiOff() }
            } message: { Text(L.s("wifi_off_confirm_body")) }
            .navigationDestination(for: Route.self) { route in
                secondaryDestination(route).toolbar(.hidden, for: .tabBar)
            }
        }
        .onAppear { if app.wantsScopeEditor { app.wantsScopeEditor = false; path = [.bucket] } }
        .onChange(of: app.wantsScopeEditor) { wants in if wants { app.wantsScopeEditor = false; path = [.bucket] } }
        .onAppear {
            switch LaunchRoute.current {
            case .bucket: path = [.bucket]
            case .storage: path = [.storage]
            case .diagnostics: path = [.diagnostics]
            case .about: path = [.about]
            default: break
            }
        }
    }

    @ViewBuilder private func secondaryDestination(_ route: Route) -> some View {
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
        case .about: AboutScreen()
        }
    }

    private var settingsSection: some View {
        ForEach(SettingsLayout.sections, id: \.self) { group in
            if let headerKey = group.headerKey {
                Section {
                    sectionBody(for: group)
                } header: {
                    sectionHeader(L.s(headerKey))
                }
                .ppTinted(PPUI.Surface.settingsCard)
            } else {
                Section {
                    sectionBody(for: group)
                }
                .ppTinted(PPUI.Surface.settingsCard)
            }
        }
    }

    @ViewBuilder private func sectionBody(for group: SettingsLayout.Group) -> some View {
        switch group {
        case .backup: backupRows
        case .selection:
            ForEach(SettingsLayout.selectionRows, id: \.self) { entry in
                SingleTransferSelectionRow(
                    title: L.s(entry.labelKey),
                    horizontalPadding: 0,
                    minHeight: nil
                ) {
                    entry.request(photos: { app.pickerRequested = true }, files: { showFilePicker = true })
                }
                .accessibilityIdentifier(entry.accessibilityID)
            }
        case .conditions:
            ForEach(SettingsLayout.conditionRows, id: \.self) { condition in
                conditionRow(condition)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(PPFont.footnote)
            .foregroundStyle(PPColor.ink40)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var backupRows: some View {
        ForEach(SettingsLayout.backupRows(autoRule: app.autoRule), id: \.self) { item in
            switch item {
            case .rule: ruleRow
            case .scope:
                if let route = item.route {
                    row(L.s("backup_scope"), value: scopeValue, route: route)
                }
            case .background:
                Toggle(L.s("auto_backup_pause"), isOn: Binding(get: { app.autoBackup }, set: { app.setAutoBackup($0) }))
                    .font(Self.labelFont).tint(PPColor.safe)
            }
        }
        if let n = app.cancelRemainingCount {
            Button {
                Task {
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

    @ViewBuilder private func conditionRow(_ condition: SettingsLayout.Condition) -> some View {
        switch condition {
        case .wifi:
            Toggle(L.s("setting_wifi_only"), isOn: Binding(get: { app.wifiOnly }, set: { app.setWifiOnly($0) }))
                .font(Self.labelFont).tint(PPColor.safe)
        case .notifications:
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L.s("rule_notify"), isOn: Binding(get: { app.notifyToggleOn }, set: { app.setNotifyToggle($0) }))
                    .font(Self.labelFont).tint(PPColor.safe)
                if app.notificationAuthorization == .denied {
                    Text(L.s("rule_notify_denied_hint")).font(Self.hintFont).foregroundStyle(PPColor.ink40)
                }
            }
        case .more:
            if let route = condition.route {
                row(L.s("more_label"), value: "", route: route)
            }
        }
    }

    private var moreScreen: some View {
        List {
            Section {
                row(L.s("storage_computer"), value: "", route: .storage)
                row(L.s("setting_version"), value: AppVersion.current.displayLine, route: .diagnostics)
                row(L.s("about_label"), value: "", route: .about)
            }
            .ppTinted(PPUI.Surface.settingsCard)
        }
        .listStyle(.insetGrouped)
        .ppList()
        .ppNavBar()
        .navigationTitle(L.s("more_label"))
        .navigationBarTitleDisplayMode(.inline)
    }

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

    private static let labelFont = PPFont.sans(PPUI.TextSize.rowLabel)
    private static let valueFont = PPFont.sans(PPUI.TextSize.rowValue, relativeTo: .subheadline)
    private static let hintFont = PPFont.sans(PPUI.TextSize.rowHint, relativeTo: .footnote)

    static func scopeValueText(unreadable: Bool, albumCount: Int?, folderCount: Int, since: BackupSince?,
                               now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if unreadable { return L.s("backup_scope_unreadable") }
        let albums = albumCount.flatMap { $0 > 0 ? L.p("backup_scope_n", $0) : nil }
        let folders = folderCount > 0 ? L.p("backup_scope_folder_n", folderCount) : nil
        let sources = [albums, folders].compactMap { $0 }.joined(separator: " · ")
        guard !sources.isEmpty else { return L.s("backup_scope_none") }
        guard let since, case .since = since else { return sources }
        return L.f("backup_scope_with_time", sources, timeLabel(since, now: now, calendar: calendar, locale: locale))
    }

    private var scopeValue: String {
        Self.scopeValueText(unreadable: app.scopeUnreadable, albumCount: app.selectedAlbumCount,
                            folderCount: app.selectedFolderCount, since: app.since, now: Date())
    }

    static func timeLabel(_ since: BackupSince, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard case .since(let ms) = since else { return "" }
        return L.f("scope_value_since", scopeDate(Date(timeIntervalSince1970: Double(ms) / 1000), calendar: calendar, locale: locale))
    }

    static func scopeDate(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    private func row(_ title: String, value: String, route: Route) -> some View {
        NavigationLink(value: route) {
            LabeledContent {
                Text(value).font(Self.valueFont).foregroundStyle(PPColor.ink40).lineLimit(2).multilineTextAlignment(.trailing)
            } label: {
                Text(title).font(Self.labelFont).foregroundStyle(PPColor.ink)
            }
        }
    }
}

struct NoticeRow: View {
    let text: String
    var action: (String, () -> Void)? = nil
    var dismiss: (String, () -> Void)? = nil
    var close: (String, () -> Void)? = nil
    var standalone = false

    var body: some View {
        if let c = close {
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

// PHPickerConfiguration() 不传 photoLibrary 走进程外选择器，无需照片权限；.current 保留原始文件字节以保证哈希一致
struct PhotoPickerSheet: UIViewControllerRepresentable {
    static let mediaFilter: PHPickerFilter = .any(of: [.images, .videos])

    let onPicked: ([PHPickerResult]) -> Void
    @Environment(\.dismiss) private var dismiss

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
            // 先把选中结果同步交回 AppModel 再 dismiss，避免 sheet 关闭触发 didSet 误记成 picker cancelled（#1453）
            if !results.isEmpty { parent.onPicked(results) }
            parent.dismiss()
        }
    }
}
