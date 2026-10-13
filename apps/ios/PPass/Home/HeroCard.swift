import PPassCore
import SwiftUI
import UIKit

/// 英雄卡（规则 H：主位四选一）+ 分隔线下的进度区 / 状态行 + 右侧唯一的次级按钮。
/// 是 `List(.insetGrouped)` 里的第一个分组：一行放数字 / 引导，一行放进度与状态。
struct HeroCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let triplet = app.triplet
        let render = HomeProjection.heroRender(app.access, triplet)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                switch render {
                case .accessBlocked: accessCard
                case .unreadable:
                    Text(L.s("triplet_unavailable")).font(.body).foregroundStyle(.secondary)
                case .unreconciled:
                    Text(L.s("hero_unreconciled_title")).font(.title2.bold())
                    Text(L.s("hero_unreconciled_body")).font(.body).foregroundStyle(.secondary)
                case .triplet:
                    if let triplet { tripletView(triplet) }
                }
            }
            .padding(.vertical, 6)
            .ppTinted(render == .accessBlocked ? PPTone.act : nil)
            if render != .accessBlocked {
                progressRow.padding(.vertical, 4)
            }
        }
    }

    /// MOB-02 / MOB-94：权限不全时整块数字被引导卡顶替——不显示任何数，就不会盖「都存好了」的章。
    private var accessCard: some View {
        let partial = app.access == .partial
        return VStack(alignment: .leading, spacing: 10) {
            Label(L.s(partial ? "partial_access_title" : "no_media_access_title"), systemImage: "photo.badge.exclamationmark")
                .font(.title3.bold()).foregroundStyle(PPTone.act)
            Text(L.s(partial ? "partial_access_body" : "no_media_access_body")).font(.body)
                .foregroundStyle(.secondary)
            PPButton(title: L.s("partial_access_action"), kind: .danger) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private func tripletView(_ t: BackupTriplet) -> some View {
        let safe = HomeProjection.heroNumberIsSafe(app.access, t, pairingLost: app.pairingLost)
        let color = safe ? PPTone.safe : Color.primary
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.m.formatted()).font(.system(size: 48, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(L.f("hero_of_n", t.n.formatted())).font(.headline).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.m.formatted()).font(.system(size: 48, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(L.f("hero_of_n", t.n.formatted())).font(.headline)
                }
            }
            .foregroundStyle(color)
            Text(lastLine(t)).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func lastLine(_ t: BackupTriplet) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let when: String
        switch HomeProjection.lastSuccess(ts: t.lastSuccessAt, now: now) {
        case .never: when = L.s("last_success_never")
        case .justNow: when = L.f("dog_last_success", L.s("last_just_now"))
        case .minutesAgo(let m): when = L.f("dog_last_success", L.f("last_mins_ago", Int(m)))
        case .hoursAgo(let h): when = L.f("dog_last_success", L.f("last_hours_ago", Int(h)))
        case .at(let ts):
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            when = L.f("dog_last_success", f.string(from: Date(timeIntervalSince1970: Double(ts) / 1000)))
        }
        return t.k > 0 ? when + " · " + L.f("pending_count", Int(t.k)) : when
    }

    private var progressRow: some View {
        let state = app.uiState
        let action = HomeProjection.heroAction(state, pairingLost: app.pairingLost)
        return VStack(alignment: .leading, spacing: 10) {
            if case .sending(let done, let total, let file) = state {
                Label {
                    Text(file).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(PPTone.waiting)
                }
                Text(L.f("state_sending", done, total)).font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(done - 1), total: Double(max(total, 1))).tint(PPTone.waiting)
            } else {
                Label {
                    Text(statusText(state)).font(.body).foregroundStyle(statusColor(state))
                } icon: {
                    Image(systemName: statusSymbol(state)).foregroundStyle(statusColor(state))
                }
            }
            if let action {
                Button(L.s(app.commandInFlight ? "backup_command_processing" : (action == .pause ? "backup_pause" : "backup_resume"))) {
                    app.pauseOrResume()
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(app.commandInFlight)
            }
        }
    }

    private func statusText(_ s: BackupUiState) -> String {
        if case .waiting(let r) = s { return L.s(HomeProjection.waitTextKey(r)) }
        if s == .preparing { return L.s("state_preparing") }
        switch HomeProjection.statusLine(s, pendingK: app.triplet?.k ?? 0) {
        case .noAlbums: return L.s("state_no_albums")
        case .pending(let k): return L.p("state_pending", Int(k))
        case .paused: return L.s("state_paused")
        case .trouble: return L.s("state_trouble")
        case .allSafe:
            let allowed = HomeProjection.allSafeTextAllowed(app.access, app.triplet, pairingLost: app.pairingLost,
                                                            missingSource: app.facts.missingSourceUnacknowledged)
            return L.s(allowed ? "state_safe" : "idle_auto_hint")
        case .ready, .working, .waiting: return L.s("idle_auto_hint")
        }
    }

    /// 绿色只给「已确认的安全」——状态行说「都存好了」且闸门放行时才绿；等待用琥珀；其余用系统次级色。
    private func statusColor(_ s: BackupUiState) -> Color {
        if case .waiting = s { return PPTone.waiting }
        if isConfirmedSafe(s) { return PPTone.safe }
        return .secondary
    }

    private func isConfirmedSafe(_ s: BackupUiState) -> Bool {
        if case .allSafe = HomeProjection.statusLine(s, pendingK: app.triplet?.k ?? 0),
           HomeProjection.allSafeTextAllowed(app.access, app.triplet, pairingLost: app.pairingLost,
                                             missingSource: app.facts.missingSourceUnacknowledged) {
            return true
        }
        return false
    }

    /// 状态图标（SF Symbols），与 Android 状态行的语义一一对应：存好 / 等待 / 暂停 / 出问题 / 其余。
    private func statusSymbol(_ s: BackupUiState) -> String {
        if case .waiting = s { return "clock" }
        if s == .preparing { return "hourglass" }
        switch HomeProjection.statusLine(s, pendingK: app.triplet?.k ?? 0) {
        case .noAlbums: return "photo.on.rectangle.angled"
        case .pending: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .trouble: return "exclamationmark.triangle"
        case .allSafe: return isConfirmedSafe(s) ? "checkmark.circle.fill" : "clock"
        case .ready, .working, .waiting: return "clock"
        }
    }
}
