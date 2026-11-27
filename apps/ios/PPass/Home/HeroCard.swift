import PPassCore
import SwiftUI
import UIKit

struct HeroCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let triplet = app.triplet
        let render = HomeProjection.heroRender(app.access, triplet, countsReadable: app.facts.countsReadable, scopeSaved: !app.noAlbums,
                                               hasUsableSource: app.backupAvailability.hasUsableSource,
                                               hasSelectedAlbum: app.sourceAvailability.hasSelectedAlbum,
                                               mixedAlbumIncomplete: app.showsMixedAlbumIncomplete)
        let fromTodayEmpty = Self.showsFromTodayEmpty(render: render, triplet: triplet, since: app.since)
        let allSafeAllowed = HomeProjection.allSafeTextAllowed(app.access, triplet, connection: app.connection,
                                                               missingSource: app.facts.missingSourceUnacknowledged)
        let tone = HomeProjection.heroSurfaceTone(autoRule: app.autoRule, render: render, uiState: app.uiState,
                                                  triplet: triplet, fromTodayEmpty: fromTodayEmpty, allSafeAllowed: allSafeAllowed)
        Section {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if !app.autoRule {
                        Text(L.s("auto_backup_off_hero")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    } else {
                    switch render {
                    case .accessBlocked:
                        Text(L.s("auto_backup_blocked_hero")).font(PPFont.cardTitle).foregroundStyle(PPColor.act)
                        if app.blockedHeroOffersSettings {
                            HeroCompactActionButton(title: L.s("auto_backup_blocked_action")) { app.openSettingsFromBlockedHero() }
                                .accessibilityIdentifier("blockedHeroSettings")
                        }
                    case .mixedAlbumIncomplete:
                        Text(L.s("hero_mixed_album_incomplete")).font(PPFont.cardTitle).foregroundStyle(PPColor.act)
                        HeroCompactActionButton(title: L.s("hero_adjust_scope_action")) { app.adjustScopeFromIncompleteAlbum() }
                            .accessibilityIdentifier("mixedAlbumAdjustScope")
                    case .countsUnreadable:
                        Text(L.s("hero_counts_unreadable")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .noAlbums:
                        Text(L.s("backup_scope_none")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .unreadable:
                        Text(L.s("triplet_unavailable")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .unreconciled:
                        Text(L.s("hero_unreconciled_title")).font(PPFont.cardTitle).foregroundStyle(PPColor.waiting)
                        Text(L.s("hero_unreconciled_body")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .triplet:
                        if fromTodayEmpty {
                            Text(L.s("auto_backup_from_today_empty")).font(PPFont.cardBody).foregroundStyle(PPColor.ink)
                        } else if let triplet {
                            tripletView(triplet)
                        }
                    }
                    }
                }
                if render != .accessBlocked || !app.autoRule {
                    Rectangle().fill(Self.dividerColor(tone)).frame(height: 1)
                        .padding(.top, PPUI.Layout.heroDividerAbove).padding(.bottom, PPUI.Layout.heroDividerBelow)
                    progressRow
                }
                if let line = HomeProjection.pickedLine(app.pickedBatch) {
                    Text(line).font(PPFont.sans(PPUI.TextSize.statusLine, .medium, relativeTo: .footnote))
                        .foregroundStyle(PPColor.ink60).padding(.top, 8)
                        .accessibilityIdentifier("pickedStatus")
                }
                if let line = HomeProjection.pickedInterruptedLine(app.pickedBatch) {
                    Text(line).font(PPFont.sans(PPUI.TextSize.statusLine, .medium, relativeTo: .footnote))
                        .foregroundStyle(PPColor.waiting).padding(.top, 8)
                        .accessibilityIdentifier("pickedInterrupted")
                }
            }
            .padding(.vertical, 6)
            .ppTinted(Self.surfaceBackground(tone))
        } footer: {
            if let free = app.facts.view?.desktopFreeBytes, free < DesktopHealth.lowSpaceBytes {
                Text(L.s("desktop_low_space_hint"))
                    .font(PPFont.sans(PPUI.TextSize.statusLine, .medium, relativeTo: .footnote))
                    .foregroundStyle(PPColor.waiting).textCase(nil)
            }
        }
    }

    private func tripletView(_ t: BackupTriplet) -> some View {
        let safe = HomeProjection.heroNumberIsSafe(app.access, t, connection: app.connection)
        let color = safe ? PPColor.safe : PPColor.ink
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: PPUI.Layout.heroOfNGap) {
                    Text(t.m.formatted()).font(PPFont.heroNumber).lineLimit(1)
                    Text(L.f("hero_of_n", t.n.formatted())).font(PPFont.heroOfN).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.m.formatted()).font(PPFont.heroNumber).lineLimit(1).minimumScaleFactor(0.5)
                    Text(L.f("hero_of_n", t.n.formatted())).font(PPFont.heroOfN)
                }
            }
            .foregroundStyle(color)
            Text(Self.lastLine(t)).font(PPFont.sans(PPUI.TextSize.heroMeta, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60)
        }
    }

    internal static func lastLine(_ t: BackupTriplet) -> String {
        LastSuccessText.line(t.lastSuccessAt)
    }

    internal static func surfaceBackground(_ tone: HeroSurfaceTone) -> Color {
        switch tone {
        case .act: return PPColor.actBg
        case .waiting: return PPColor.waitingBg
        case .neutral: return PPColor.linen
        case .safe: return PPColor.safeBg
        }
    }

    internal static func dividerColor(_ tone: HeroSurfaceTone) -> Color {
        switch tone {
        case .act: return PPColor.act.opacity(0.18)
        case .waiting: return PPColor.waiting.opacity(0.18)
        case .neutral: return PPColor.hairline
        case .safe: return PPColor.safe.opacity(0.18)
        }
    }

    internal static func showsFromTodayEmpty(render: HeroRender, triplet: BackupTriplet?,
                                             since: BackupSince?) -> Bool {
        guard render == .triplet, let t = triplet, t.n == 0, t.m == 0 else { return false }
        if case .since? = since { return true }
        return false
    }

    private var progressRow: some View {
        let state = app.uiState
        let action = HomeProjection.heroAction(state, connection: app.connection)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                if state.isRunning { transferSlots(state) } else if let text = statusText(state) {
                    Text(text).font(PPFont.statusLine).foregroundStyle(statusColor(state))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(L.s(app.commandInFlight ? "backup_command_processing" : (action == .pause ? "backup_pause" : "backup_resume"))) {
                    app.pauseOrResume()
                }
                .buttonStyle(PPChipButtonStyle())
                .disabled(app.commandInFlight)
            }
        }
        .frame(minHeight: PPUI.Layout.heroProgressRowMinHeight, alignment: .center)
    }

    @ViewBuilder private func transferSlots(_ state: BackupUiState) -> some View {
        let v = app.facts.view
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let quiet = quietSeconds(now: ctx.date)
            let slow = quiet >= TransferText.slowAfterSeconds
            VStack(alignment: .leading, spacing: 0) {
                if case .fetchingFromICloud(let done, let total, let file, let fraction) = state {
                    Text(file).font(PPFont.sans(13.5, .medium)).foregroundStyle(PPColor.ink60)
                        .lineLimit(1).truncationMode(.middle)
                    Text(L.f("state_fetching_icloud", Int(((fraction ?? 0) * 100).rounded()), done, total))
                        .font(PPFont.sans(13)).foregroundStyle(PPColor.ink60).lineLimit(1)
                } else if case .sending(let done, let total, let file) = state {
                    Text(file).font(PPFont.sans(13.5, .medium)).foregroundStyle(PPColor.ink60)
                        .lineLimit(1).truncationMode(.middle)
                    Text(slow ? L.f("state_sending_slow", quiet)
                         : TransferText.bytes(v?.currentBytesSent ?? 0, v?.currentTotalBytes ?? 0)
                            .map { L.f("state_sending_detail", $0, done, total) } ?? L.f("state_sending", done, total))
                        .font(PPFont.sans(13)).foregroundStyle(slow ? PPColor.waiting : PPColor.ink60).lineLimit(1)
                } else {
                    Text(statusText(state) ?? " ").font(PPFont.sans(13.5, .medium)).foregroundStyle(PPColor.ink60).lineLimit(1)
                    Text(" ").font(PPFont.sans(13)).lineLimit(1)
                }
                Spacer().frame(height: 8)
                if case .fetchingFromICloud(_, _, _, let fraction?) = state {
                    PPProgressBar(value: fraction, total: 1, tint: PPColor.safe, track: PPColor.safe.opacity(0.18))
                } else if let v, v.currentTotalBytes > 0, case .sending = state {
                    let tint = slow ? PPColor.waiting : PPColor.safe
                    PPProgressBar(value: Double(v.currentBytesSent), total: Double(v.currentTotalBytes),
                                  tint: tint, track: tint.opacity(0.18))
                } else {
                    Color.clear.frame(height: 6)
                }
            }
        }
    }

    private func quietSeconds(now: Date) -> Int {
        guard let m = app.transferMark, m.orderId == app.facts.view?.currentOrderId,
              m.bytes == app.facts.view?.currentBytesSent else { return 0 }
        if let v = app.facts.view, TransferText.isFinishing(sent: v.currentBytesSent, total: v.currentTotalBytes) { return 0 }
        return max(Int(now.timeIntervalSince(m.at)), 0)
    }

    private func statusText(_ s: BackupUiState) -> String? {
        if case .waiting(let r) = s { return L.s(HomeProjection.waitTextKey(r)) }
        if s == .preparing { return L.s("state_preparing") }
        switch HomeProjection.statusLine(s, pendingK: app.triplet?.k ?? 0) {
        case .noAlbums: return nil
        case .pending(let k): return L.p("state_pending", Int(k))
        case .paused: return L.s("state_paused")
        case .trouble: return L.s("state_trouble")
        case .allSafe:
            let allowed = HomeProjection.allSafeTextAllowed(app.access, app.triplet, connection: app.connection,
                                                            missingSource: app.facts.missingSourceUnacknowledged)
            return allowed ? L.s("state_safe") : nil
        case .ready, .working, .waiting: return nil
        }
    }

    internal static func heroIdleLineColor(hasWaitReason: Bool, line: StatusLine, allSafeAllowed: Bool) -> Color {
        if hasWaitReason { return PPColor.waiting }
        if case .allSafe = line, allSafeAllowed { return PPColor.safe }
        return PPColor.ink60
    }

    private func statusColor(_ s: BackupUiState) -> Color {
        let hasWait: Bool
        if case .waiting = s { hasWait = true } else { hasWait = false }
        let line = HomeProjection.statusLine(s, pendingK: app.triplet?.k ?? 0)
        let allowed = HomeProjection.allSafeTextAllowed(app.access, app.triplet, connection: app.connection,
                                                        missingSource: app.facts.missingSourceUnacknowledged)
        return Self.heroIdleLineColor(hasWaitReason: hasWait, line: line, allSafeAllowed: allowed)
    }
}

struct HeroActionButtonStyleConfig: Equatable {
    var height: CGFloat = 40
    var cornerRadius: CGFloat = 14
    var borderWidth: CGFloat = 1
    var borderOpacity: Double = 0.4
    var fontSize: CGFloat = 15
    var horizontalPadding: CGFloat = 16

    static let standard = HeroActionButtonStyleConfig()

    var borderColor: Color { PPColor.act.opacity(borderOpacity) }
    var contentColor: Color { PPColor.act }
}

struct HeroCompactActionButton: View {
    let title: String
    var style: HeroActionButtonStyleConfig = .standard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PPFont.sans(style.fontSize, .bold))
                .foregroundStyle(style.contentColor)
                .padding(.horizontal, style.horizontalPadding)
                .frame(height: style.height)
                .background(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
                )
        }
        .buttonStyle(.plain)
    }
}
