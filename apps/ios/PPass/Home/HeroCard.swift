import PPassCore
import SwiftUI
import UIKit

/// 英雄卡（规则 H：主位四选一）+ 分隔线下的进度区 / 状态行 + 右侧唯一的次级按钮。
/// 是 `List(.insetGrouped)` 里的第一个分组：一行放数字 / 引导，一行放进度与状态。
struct HeroCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let triplet = app.triplet
        let render = HomeProjection.heroRender(app.access, triplet, countsReadable: app.facts.countsReadable, scopeSaved: app.scope != nil)
        Section {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    switch render {
                    case .accessBlocked: accessCard
                    case .countsUnreadable:
                        Text(L.s("hero_counts_unreadable")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .noAlbums:
                        Text(L.s("backup_scope_none")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .unreadable:
                        Text(L.s("triplet_unavailable")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .unreconciled:
                        // Android：16 粗体 waiting 色——琥珀 = 「在等它自己算完」，不是结论，不用大号衬线。
                        Text(L.s("hero_unreconciled_title")).font(PPFont.cardTitle).foregroundStyle(PPColor.waiting)
                        Text(L.s("hero_unreconciled_body")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                    case .triplet:
                        if let triplet { tripletView(triplet) }
                    }
                }
                if render != .accessBlocked {
                    // 设计稿：hero 内分隔线 = safe 18%（绿系），与整卡 safe-bg 同色系，不再是系统行分隔线。
                    Rectangle().fill(PPColor.safe.opacity(0.18)).frame(height: 1)
                        .padding(.top, PPUI.Layout.heroDividerAbove).padding(.bottom, PPUI.Layout.heroDividerBelow)
                    progressRow
                }
            }
            .padding(.vertical, 6)
            .ppTinted(render == .accessBlocked ? PPColor.actBg : PPColor.safeBg)
        } footer: {
            // 桌面空间不足：Android 是英雄卡下方、卡外的一行琥珀小字（不加底、不成卡），iOS 对位分组脚注。
            if let free = app.facts.view?.desktopFreeBytes, free < DesktopHealth.lowSpaceBytes {
                Text(L.s("desktop_low_space_hint"))
                    .font(PPFont.sans(PPUI.TextSize.statusLine, .medium, relativeTo: .footnote))
                    .foregroundStyle(PPColor.waiting).textCase(nil)
            }
        }
    }

    /// MOB-02 / MOB-94：权限不全时整块数字被引导卡顶替——不显示任何数，就不会盖「都存好了」的章。
    private var accessCard: some View {
        let partial = app.access == .partial
        return VStack(alignment: .leading, spacing: 10) {
            Text(L.s(partial ? "partial_access_title" : "no_media_access_title"))
                .font(PPFont.cardTitle).foregroundStyle(PPColor.act)
            Text(L.s(partial ? "partial_access_body" : "no_media_access_body")).font(PPFont.cardBody)
                .foregroundStyle(PPColor.ink60)
            // 「去设置」不是危险操作：同 Android 用 ink 主按钮，红色只留给标题说「需要处理」。
            PPButton(title: L.s("partial_access_action")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private func tripletView(_ t: BackupTriplet) -> some View {
        let safe = HomeProjection.heroNumberIsSafe(app.access, t, pairingLost: app.pairingLost)
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
            Text(lastLine(t)).font(PPFont.sans(PPUI.TextSize.heroMeta, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60)
        }
    }

    private func lastLine(_ t: BackupTriplet) -> String {
        let when = LastSuccessText.line(t.lastSuccessAt)
        return t.k > 0 ? when + " · " + L.f("pending_count", Int(t.k)) : when
    }

    /// 进度区（Android 同构）：左 = 文字列，右 = 唯一的次级按钮（进行中「暂停」/ 已暂停「继续」，其余不出现）。
    /// 进行中是固定三格——文件名 / 字节行 / 进度条槽——各单行，换文件、准备 ↔ 备份都不改变高度。
    private var progressRow: some View {
        let state = app.uiState
        let action = HomeProjection.heroAction(state, pairingLost: app.pairingLost)
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
    }

    @ViewBuilder private func transferSlots(_ state: BackupUiState) -> some View {
        let v = app.facts.view
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let quiet = quietSeconds(now: ctx.date)
            let slow = quiet >= TransferText.slowAfterSeconds
            VStack(alignment: .leading, spacing: 0) {
                if case .fetchingFromICloud(let done, let total, let file, let fraction) = state {
                    // #1092：原图正从 iCloud 下载，还没有字节流向电脑——不显示「没有新数据」。
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
                    // 固定三格：没有状态行时也占住这一格，高度不跳。
                    Text(statusText(state) ?? " ").font(PPFont.sans(13.5, .medium)).foregroundStyle(PPColor.ink60).lineLimit(1)
                    Text(" ").font(PPFont.sans(13))
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
        // 对齐 Android FINISHING：字节已全部发出、在等电脑确认收下，不动是正常的，不算「没有新数据」。
        if let v = app.facts.view, TransferText.isFinishing(sent: v.currentBytesSent, total: v.currentTotalBytes) { return 0 }
        return max(Int(now.timeIntervalSince(m.at)), 0)
    }

    /// 状态行；nil = 不渲染（10-29 文案 B12：iOS 首页不再有「打开 P-Pass 时自动备份」这一行，后台备份只靠设置页卡片引导）。
    private func statusText(_ s: BackupUiState) -> String? {
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
            return allowed ? L.s("state_safe") : nil
        case .ready, .working, .waiting: return nil
        }
    }

    /// 绿色只给「已确认的安全」——状态行说「都存好了」且闸门放行时才绿；等待用琥珀；其余用系统次级色。
    private func statusColor(_ s: BackupUiState) -> Color {
        if case .waiting = s { return PPColor.waiting }
        if isConfirmedSafe(s) { return PPColor.safe }
        return PPColor.ink60
    }

    private func isConfirmedSafe(_ s: BackupUiState) -> Bool {
        if case .allSafe = HomeProjection.statusLine(s, pendingK: app.triplet?.k ?? 0),
           HomeProjection.allSafeTextAllowed(app.access, app.triplet, pairingLost: app.pairingLost,
                                             missingSource: app.facts.missingSourceUnacknowledged) {
            return true
        }
        return false
    }
}
