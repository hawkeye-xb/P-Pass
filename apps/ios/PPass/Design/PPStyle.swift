import SwiftUI
import UIKit

/// 品牌语义层（#943）。
///
/// 组件用 SwiftUI 原生的（TabView / NavigationStack / List / SF Symbols / 系统转场），**设计语言是品牌基础、
/// 与 Android 一致**：颜色只用 tokens.json 生成的 `PPColor`、字体只用 Manrope（正文 / UI）+ Newsreader（标题 / 结论句）、
/// 界面只有浅色（Info.plist `UIUserInterfaceStyle=Light`，对位 Android `Theme.Material.Light`；扫码 / 看图 / 视频
/// 这类 Android 用 `surface-dark` 的屏才是深色）。不使用系统语义色（tools/ios/check-no-color-literals.sh 守门）。
/// 这里不写任何色值字面量（同一个脚本）。

/// 品牌字体。全部 `Font.custom(_, size:, relativeTo:)`，随 Dynamic Type 缩放。
/// 字重对位 Android `PPFont`：Manrope Regular / Medium / Bold，Newsreader Regular / Medium / SemiBold。
enum PPFont {
    /// 品牌字体的 PostScript 名（tools/ios/prepare-fonts.py 生成的字体文件，Info.plist UIAppFonts 注册）。
    static let faces = [
        "Newsreader-Regular", "Newsreader-Medium", "Newsreader-SemiBold",
        "Manrope-Regular", "Manrope-Medium", "Manrope-Bold",
    ]

    static func sansFace(_ weight: Font.Weight) -> String {
        "\(PPFontFamily.sans)-" + (weight == .bold || weight == .semibold || weight == .heavy ? "Bold" : (weight == .medium ? "Medium" : "Regular"))
    }

    static func serifFace(_ weight: Font.Weight) -> String {
        "\(PPFontFamily.serif)-" + (weight == .bold || weight == .semibold || weight == .heavy ? "SemiBold" : (weight == .medium ? "Medium" : "Regular"))
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(sansFace(weight), size: size, relativeTo: style)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(serifFace(weight), size: size, relativeTo: style)
    }

    // 语义字号（手机正文 ≥17，tokens.json rules）。标题 / 结论句走衬线，其余走无衬线。
    static var body: Font { sans(PPSize.bodyMin) }
    static var bodyMedium: Font { sans(PPSize.bodyMin, .medium) }
    static var bodyBold: Font { sans(PPSize.bodyMin, .bold) }
    static var subheadline: Font { sans(15, relativeTo: .subheadline) }
    static var subheadlineBold: Font { sans(15, .bold, relativeTo: .subheadline) }
    static var footnote: Font { sans(13, relativeTo: .footnote) }
    static var caption: Font { sans(12, relativeTo: .caption) }
    static var captionBold: Font { sans(12, .bold, relativeTo: .caption) }
    /// 等宽（诊断细节 / 配对串）：Manrope 没有等宽，退到系统等宽，只用于代码样的文本。
    static var mono: Font { .system(.body, design: .monospaced) }
    static var monoSmall: Font { .system(.footnote, design: .monospaced) }
    static var headline: Font { serif(18, relativeTo: .headline) }
    static var title3: Font { serif(24, relativeTo: .title3) }
    static var title2: Font { serif(30, relativeTo: .title2) }
    static var largeTitle: Font { serif(36, relativeTo: .largeTitle) }
    /// 首页英雄数字（Android HomeScreen 40sp Newsreader）。
    static var heroNumber: Font { serif(40, relativeTo: .largeTitle) }
    static func brand(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font { serif(size, relativeTo: style) }
}

/// 压在深色面（surface-dark）上的次级文字：paper 62%（Android `PPColor.PaperDim`，与 tokens.json 同源的 paper 叠透明度）。
extension PPColor {
    static let paperDim = PPColor.paper.opacity(0.62)
}

/// 全局 UIKit 外观：导航栏 / Tab 栏 / 分段控件的颜色与字体取 token（SwiftUI 的 `toolbarBackground` 管背景，
/// 字体与分段控件只有 UIKit appearance 能管）。在 App 启动时调一次。
enum PPAppearance {
    static func install() {
        let paper = UIColor(PPColor.paper), ink = UIColor(PPColor.ink)
        let hairline = UIColor(PPColor.hairline), ink40 = UIColor(PPColor.ink40)
        func ui(_ name: String, _ size: CGFloat) -> UIFont { UIFont(name: name, size: size) ?? .systemFont(ofSize: size) }

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = paper
        nav.shadowColor = hairline
        nav.titleTextAttributes = [.foregroundColor: ink, .font: ui(PPFont.sansFace(.bold), 17)]
        nav.largeTitleTextAttributes = [.foregroundColor: ink, .font: ui(PPFont.serifFace(.semibold), 34)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = paper
        tab.shadowColor = hairline
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = ink40
            item.normal.titleTextAttributes = [.foregroundColor: ink40, .font: ui(PPFont.sansFace(.medium), 11)]
            item.selected.iconColor = ink
            item.selected.titleTextAttributes = [.foregroundColor: ink, .font: ui(PPFont.sansFace(.bold), 11)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let seg = UISegmentedControl.appearance()
        seg.backgroundColor = UIColor(PPColor.linen)
        seg.selectedSegmentTintColor = ink
        seg.setTitleTextAttributes([.foregroundColor: UIColor(PPColor.ink60), .font: ui(PPFont.sansFace(.medium), 15)], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: paper, .font: ui(PPFont.sansFace(.bold), 15)], for: .selected)
    }
}

/// 触感反馈。`sensoryFeedback` 是 iOS 17+，最低 iOS 16，所以直接用 UIKit 生成器（两个版本都可用）。
enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// 主 / 次 / 危险按钮（Android `PPButton`）：高 56、圆角 20、Manrope Bold；主 = ink 底 paper 字，
/// 次 = paper 底 + border-strong 描边 + ink-60 字，危险 = act 底。二选一的两个按钮同组件、同高、等宽（tokens.json）。
struct PPButton: View {
    enum Kind { case main, quiet, danger }
    let title: String
    var kind: Kind = .main
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PPFont.bodyBold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: PPSize.tapMin)
        }
        .buttonStyle(PPButtonStyle(kind: kind))
        .disabled(!enabled)
    }
}

struct PPButtonStyle: ButtonStyle {
    let kind: PPButton.Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(kind == .quiet ? PPColor.ink60 : PPColor.paper)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: PPRadius.controlMobile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PPRadius.controlMobile, style: .continuous)
                    .stroke(kind == .quiet ? PPColor.borderStrong : Color.clear, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .main: return pressed ? PPColor.inkHover : PPColor.ink
        case .danger: return PPColor.act
        case .quiet: return PPColor.paper
        }
    }
}

/// 行内的次级小按钮（暂停 / 继续、重试）：paper 底 + border-strong 描边 + ink-60 字，高度随字。
struct PPChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PPFont.sans(15, .bold, relativeTo: .subheadline))
            .foregroundStyle(PPColor.ink60)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(PPColor.paper, in: RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous).stroke(PPColor.borderStrong, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}

/// 居中的整屏提示（空态 / 加载态 / 错误态共用的形状）。
struct PPStateMessage: View {
    let text: String
    var symbol: String?
    var loading = false
    var actionTitle: String?
    var action: (() -> Void)?
    /// 深色面（扫码 / 看图）上用 paper 系文字。
    var onDark = false

    var body: some View {
        VStack(spacing: 14) {
            if loading {
                ProgressView().tint(onDark ? PPColor.paperDim : PPColor.ink60)
            } else if let symbol {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(onDark ? PPColor.paperDim : PPColor.ink40)
            }
            Text(text).font(PPFont.body).foregroundStyle(onDark ? PPColor.paperDim : PPColor.ink60).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PPChipButtonStyle())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 屏内浮出的短提示（保存成功 / 失败）：ink 胶囊 + paper 字，约 2 秒自动消失。
struct PPToast: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(PPFont.sans(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(PPColor.paper)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(PPColor.ink, in: Capsule())
                    .overlay(Capsule().stroke(PPColor.paper.opacity(0.3), lineWidth: 1))
                    .padding(.bottom, 72)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.text = nil }
                    }
            }
        }
        .animation(.default, value: text)
    }
}

/// 进度条：hairline 轨道 + 含义色填充（Android 同款，不用系统 ProgressView 的灰轨）。
struct PPProgressBar: View {
    let value: Double
    let total: Double
    var tint: Color = PPColor.waiting
    var track: Color = PPColor.hairline

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: geo.size.width * CGFloat(min(max(value / max(total, 1), 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(value / max(total, 1), 0), 1) * 100))%")
    }
}

/// 行内分隔线（token divider）。
struct PPDivider: View {
    var body: some View { Rectangle().fill(PPColor.divider).frame(height: 1) }
}

extension View {
    func ppToast(_ text: Binding<String?>) -> some View { modifier(PPToast(text: text)) }

    /// 原生 `List` / `Form` 套品牌：paper 底、行底 linen、分隔线 hairline、文字 ink。
    func ppList() -> some View {
        self.font(PPFont.body)
            .scrollContentBackground(.hidden)
            .background(PPColor.paper.ignoresSafeArea())
            .listRowBackground(PPColor.linen)
            .listRowSeparatorTint(PPColor.hairline)
            .foregroundStyle(PPColor.ink)
            .tint(PPColor.ink)
    }

    /// 导航栏（与 Tab 栏）底色取 paper；字体 / 分隔线在 `PPAppearance`。
    func ppNavBar() -> some View {
        self.toolbarBackground(PPColor.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// 整页 paper 底 + 默认前景 ink（不让系统 label 色漏进来）。
    func ppScreen(_ fill: Color = PPColor.paper) -> some View {
        self.foregroundStyle(PPColor.ink)
            .background(fill.ignoresSafeArea())
    }

    /// 列表行的含义色淡底（token 的 *-bg）。
    func ppTinted(_ bg: Color?) -> some View { listRowBackground(bg ?? PPColor.linen) }
}
