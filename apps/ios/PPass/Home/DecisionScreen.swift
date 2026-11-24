import SwiftUI

/// #1323 决定页（docs/decisions/2026-11-03-onboarding-gate.md 结论 1、5，对位 Android `DecisionScreen.kt`）：配对之后、进照片页之前
/// 必须做一次「备份哪些照片」的决定。只有两个出口——范围备份（主按钮）/ 单张备份（次入口），不能跳过，没有返回。
/// 版式同欢迎页：顶部一行现状（已连上哪台电脑），衬线大标题压在下半屏，主按钮 64 高 / 19 字，下面一行小字说明，
/// 次入口是欢迎页「手动输入」同一种文字链接。
struct SingleTransferSelectionRow: View {
    let title: String
    var inList = false
    let action: () -> Void

    var minimumHeight: CGFloat? { inList ? nil : PPUI.Layout.rowMinHeight }
    var disclosureSymbol: String { "chevron.right" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(PPFont.sans(PPUI.TextSize.rowLabel))
                    .foregroundStyle(PPColor.ink)
                Spacer(minLength: 8)
                Image(systemName: disclosureSymbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PPColor.ink40)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, inList ? 0 : 16)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

struct DecisionScreen: View {
    @EnvironmentObject var app: AppModel

    /// 没有电脑名时退回默认叫法，不出现「传到 。」。
    private var computerName: String {
        if let name = app.desktopName, !name.isEmpty { return name }
        return L.s("storage_device_default")
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.f("decision_connected", computerName))
                        .font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 32)
                    Text(L.s("decision_title")).font(PPFont.serif(32, .regular, relativeTo: .largeTitle))
                        .foregroundStyle(PPColor.ink).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    // 标题下一行说清选完之后会发生什么（照片传到哪台电脑），对位 Android。
                    Text(L.f("decision_destination", computerName))
                        .font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    PPButton(title: L.s("decision_choose_scope"), enabled: !app.decisionBusy, height: 64, fontSize: 19) { app.decisionChooseScope() }
                        .accessibilityIdentifier("decisionChooseScope")
                        .padding(.top, 40)
                    VStack(spacing: 0) {
                        SingleTransferSelectionRow(title: L.s("pick_from_photos_label"), action: app.decisionPickPhotos)
                            .accessibilityIdentifier("decisionPickPhotos")
                        PPDivider().padding(.leading, 16)
                        SingleTransferSelectionRow(title: L.s("pick_from_files_label"), action: app.decisionPickFiles)
                            .accessibilityIdentifier("decisionPickFiles")
                    }
                    .buttonStyle(.plain)
                    .background(PPUI.Surface.settingsCard, in: RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous)
                            .strokeBorder(PPColor.border, lineWidth: 1)
                    )
                    .opacity(app.decisionBusy ? 0.5 : 1)
                    .disabled(app.decisionBusy)
                    .padding(.top, 18)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .ppScreen()
        .onAppear { app.decisionShown() }
    }
}
