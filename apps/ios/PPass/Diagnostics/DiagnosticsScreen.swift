import SwiftUI

/// 诊断页（Android 没有这一屏；iOS 为取证加的，入口是设置卡的「版本」行）。
/// 版本号以**完整串**为准（#346：CFBundleShortVersionString 装不下 -test.N）；数据来源如实说是不是演示数据。
struct DiagnosticsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var copied = false

    var body: some View {
        List {
            section(L.s("diag_section_build"), rows: buildRows)
            section(L.s("diag_section_state"), rows: stateRows)
            Section {
                Button {
                    UIPasteboard.general.string = (buildRows + stateRows).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                    copied = true
                    Haptics.success()
                } label: {
                    Label(L.s(copied ? "diag_copied" : "diag_copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .listStyle(.insetGrouped)
        .ppList()
        .navigationTitle(L.s("diag_title"))
        .ppNavBar()
        .navigationBarTitleDisplayMode(.large)
    }

    private var buildRows: [(String, String)] {
        let v = AppVersion.current
        return [
            (L.s("diag_version_full"), v.full),
            (L.s("diag_version_short"), "\(v.short) · \(v.build)"),
            (L.s("diag_version_source"), v.source),
            (L.s("diag_bundle_id"), Bundle.main.bundleIdentifier ?? "—"),
            (L.s("diag_min_os"), Bundle.main.infoDictionary?["MinimumOSVersion"] as? String ?? "—"),
        ]
    }

    private var stateRows: [(String, String)] {
        let access: String
        switch app.access {
        case .full: access = L.s("diag_media_full")
        case .partial: access = L.s("diag_media_partial")
        case .none: access = L.s("diag_media_none")
        }
        let pairing: String
        switch app.pairing {
        case .paired(let n): pairing = "\(L.s("diag_pairing_paired")) · \(n)"
        case .lost(let n): pairing = "\(L.s("diag_pairing_lost")) · \(n)"
        case .notPaired: pairing = L.s("diag_pairing_none")
        }
        let view = app.facts.view
        let engine = view.map { "\($0.state.rawValue)\($0.waitReason.map { " · \($0.rawValue)" } ?? "") · pending \($0.pending)" } ?? "—"
        return [
            (L.s("diag_data_source"), L.s(app.backend.isDemo ? "diag_data_source_fake" : "diag_data_source_live")),
            (L.s("diag_media_access"), access),
            (L.s("diag_pairing"), pairing),
            (L.s("diag_engine"), engine),
            (L.s("diag_language"), Locale.preferredLanguages.first ?? "—"),
        ]
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        Section {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                    Text(row.1).font(PPFont.body).textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(title).font(PPFont.subheadlineBold).textCase(nil).foregroundStyle(PPColor.ink40)
        }
    }
}

/// 存储电脑详情（对位 Android 的详情子页）：状态图标 + 名称 + 配对状态 + 断开连接（`device.unpair` + 断开清单）。
struct StorageDetailScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var confirming = false
    @State private var working = false

    /// 只陈述有出处的事实：最近成功取引擎账目，配对日期取配对记录，张数取已确认数；不编数据。
    private var detailBody: String {
        if app.pairingLost { return L.s("storage_detail_lost") }
        let line1 = L.f("storage_detail_connected", LastSuccessText.fragment(app.triplet?.lastSuccessAt))
        guard let ms = app.pairedAtMs else { return line1 }
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        let line2 = L.f("storage_detail_paired", f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)),
                        (app.triplet?.m ?? 0).formatted())
        return line1 + "\n" + line2
    }

    var body: some View {
        List {
            Section {
                // Android 信息卡：状态点 9、点与名称间距 10、名称与正文间距 10。
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle().fill(app.pairingLost ? PPColor.act : PPColor.safe).frame(width: 9, height: 9)
                        Text(app.desktopName ?? L.s("storage_device_default")).font(PPFont.bodyBold)
                    }
                    Text(detailBody).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                }
                .padding(.vertical, 4)
            }
            .ppTinted(PPUI.Surface.settingsCard)
            Section {
                Button(role: .destructive) { confirming = true } label: {
                    HStack {
                        Text(L.s("disconnect"))
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working)
            }
            .ppTinted(PPUI.Surface.settingsCard)
        }
        .confirmationDialog(L.s("disconnect_armed_title"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L.s("disconnect_confirm"), role: .destructive) {
                working = true
                Task { await app.disconnect(); working = false }
            }
        } message: {
            Text(L.s("disconnect_armed_body"))
        }
        .listStyle(.insetGrouped)
        .ppList()
        .ppCardSpacing()
        .navigationTitle(L.s("storage_computer"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
