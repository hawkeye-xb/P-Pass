import SwiftUI

/// #1323 决定页（docs/decisions/2026-11-03-onboarding-gate.md 结论 1、5，对位 Android `DecisionScreen.kt`）：配对之后、进照片页之前
/// 必须做一次「备份哪些照片」的决定。只有两个出口——范围备份（主按钮）/ 单张备份（次入口），不能跳过，没有返回。
/// 版式同欢迎页：顶部一行现状（已连上哪台电脑），衬线大标题压在下半屏，主按钮 64 高 / 19 字，下面一行小字说明，
/// 次入口是欢迎页「手动输入」同一种文字链接。
struct DecisionScreen: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.f("decision_connected", app.desktopName ?? ""))
                        .font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 32)
                    Text(L.s("decision_title")).font(PPFont.serif(32, .regular, relativeTo: .largeTitle))
                        .foregroundStyle(PPColor.ink).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    PPButton(title: L.s("decision_choose_scope"), height: 64, fontSize: 19) { app.decisionChooseScope() }
                        .accessibilityIdentifier("decisionChooseScope")
                        .padding(.top, 40)
                    // iOS 补一句「之后怎么改成全部」：选了部分照片之后 iOS 不会再弹框，只能去系统设置（行业惯例写明路径）。
                    Text(L.s("decision_choose_scope_note") + "\n" + L.s("photo_access_change_later_hint"))
                        .font(PPFont.sans(14, relativeTo: .footnote)).foregroundStyle(PPColor.ink40)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L.s("decision_pick_photos")) { app.decisionPickPhotos() }
                        .font(PPFont.sans(15, .bold, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60)
                        .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 10)
                        .accessibilityIdentifier("decisionPickPhotos")
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .ppScreen()
        .onAppear { app.decisionShown() }
    }
}
