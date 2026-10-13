import SwiftUI

/// 诊断页（Android 没有这一屏；iOS 为取证加的，入口是设置卡的「版本」行）。
/// 版本号以**完整串**为准（#346：CFBundleShortVersionString 装不下 -test.N）；数据来源如实说是不是演示数据。
struct DiagnosticsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L.s("diag_title")).font(PPFont.serif(32))
                section(L.s("diag_section_build"), rows: buildRows)
                section(L.s("diag_section_state"), rows: stateRows)
                PPButton(title: L.s(copied ? "diag_copied" : "diag_copy"), kind: .secondary) {
                    UIPasteboard.general.string = (buildRows + stateRows).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                    copied = true
                }
            }
            .padding(16)
        }
        .ppScreen()
        .navigationBarTitleDisplayMode(.inline)
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
        PPCard {
            Text(title).font(PPFont.sans(13, .bold)).foregroundStyle(PPColor.ink40).textCase(.uppercase).tracking(1.5)
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0).font(PPFont.sans(15)).foregroundStyle(PPColor.ink40)
                    Text(row.1).font(PPFont.sans(17, .medium)).textSelection(.enabled)
                }
            }
        }
    }
}

/// 存储电脑详情（对位 Android 的详情子页）：状态点 + 名称 + 配对状态。断开连接放在集成步骤
/// （要走真实控制面 `device.unpair` 与断开清单），壳阶段不放一个点了没用的按钮。
struct StorageDetailScreen: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(app.pairingLost ? PPColor.act : PPColor.safe).frame(width: 12, height: 12)
                Text(app.desktopName ?? L.s("storage_device_default")).font(PPFont.serif(30))
            }
            Text(app.pairingLost ? L.s("storage_detail_lost") : L.f("storage_detail_connected", L.s("last_just_now")))
                .font(PPFont.body).foregroundStyle(PPColor.ink60)
            Spacer()
        }
        .padding(16)
        .ppScreen()
        .navigationBarTitleDisplayMode(.inline)
    }
}
