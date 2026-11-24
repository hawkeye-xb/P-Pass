import PPassCore
import SwiftUI

struct DiagnosticsScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var copied = false

    var body: some View {
        List {
            section(L.s("diag_section_build"), rows: buildRows)
            section(L.s("diag_section_state"), rows: stateRows)
            Section {
                Button {
                    DiagnosticsClipboard.copy((buildRows + stateRows).map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
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

enum PairedDateText {
    static func format(pairedAt ms: Int64, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

struct StorageDetailScreen: View {
    @EnvironmentObject var app: AppModel
    @State private var confirming = false
    @State private var working = false

    private var detailBody: String {
        storageDetailBody(app.connection,
                          lastSuccessAt: app.triplet?.lastSuccessAt,
                          pairedAtMs: app.pairedAtMs,
                          confirmedCount: app.triplet?.m ?? 0)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle().fill(storageDetailDotColor(app.connection.status)).frame(width: 9, height: 9)
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
        // iOS 26 上 confirmationDialog 表现为贴附按钮的气泡，居中 alert 更符合不可逆操作确认惯例
        .alert(L.s("disconnect_armed_title"), isPresented: $confirming) {
            Button(L.s("cancel"), role: .cancel) {}
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

struct StorageDetailLines: Equatable {
    let statusKey: String
    let takesLastSuccess: Bool
    let showPairedLine: Bool
}

func storageDetailLines(status: ConnectionState.Status, pairedAtMs: Int64?) -> StorageDetailLines {
    let hasPairedAt = (pairedAtMs ?? 0) > 0
    switch status {
    case .pairingLost:
        return StorageDetailLines(statusKey: "storage_detail_lost", takesLastSuccess: false, showPairedLine: false)
    case .connected:
        return StorageDetailLines(statusKey: "storage_detail_connected", takesLastSuccess: true, showPairedLine: hasPairedAt)
    case .reconnecting, .offline, .unknown:
        return StorageDetailLines(statusKey: "storage_detail_offline", takesLastSuccess: true, showPairedLine: hasPairedAt)
    }
}

func storageDetailDotColor(_ status: ConnectionState.Status) -> Color {
    switch status {
    case .connected: return PPColor.safe
    case .pairingLost: return PPColor.act
    case .reconnecting: return PPColor.waiting
    case .offline, .unknown: return PPColor.idle
    }
}

func storageDetailBody(_ connection: ConnectionState,
                       lastSuccessAt: Int64?,
                       pairedAtMs: Int64?,
                       confirmedCount: Int64) -> String {
    let lines = storageDetailLines(status: connection.status, pairedAtMs: pairedAtMs)
    let line1 = lines.takesLastSuccess
        ? L.f(lines.statusKey, LastSuccessText.fragment(lastSuccessAt))
        : L.s(lines.statusKey)
    guard lines.showPairedLine, let ms = pairedAtMs else { return line1 }
    let line2 = L.f("storage_detail_paired", PairedDateText.format(pairedAt: ms), confirmedCount.formatted())
    return line1 + "\n" + line2
}
