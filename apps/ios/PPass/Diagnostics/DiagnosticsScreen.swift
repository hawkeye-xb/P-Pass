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

    var body: some View {
        List {
            Section {
                Label {
                    Text(app.pairingLost ? L.s("storage_detail_lost") : L.f("storage_detail_connected", L.s("last_just_now")))
                        .font(PPFont.body)
                } icon: {
                    Image(systemName: app.pairingLost ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(app.pairingLost ? PPColor.act : PPColor.safe)
                }
            }
            Section {
                Button(role: .destructive) { confirming = true } label: {
                    HStack {
                        Text(L.s("disconnect"))
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working)
            }
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
        .navigationTitle(app.desktopName ?? L.s("storage_device_default"))
        .navigationBarTitleDisplayMode(.large)
    }
}
