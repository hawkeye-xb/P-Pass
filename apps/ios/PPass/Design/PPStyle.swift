import SwiftUI
import UIKit

/// iOS 原生化后的语义层（#943）。
///
/// 原则：界面走系统语义——系统字体（Dynamic Type）、`.primary`/`.secondary`、`systemGroupedBackground`、
/// 材质、SF Symbols、系统 List / TabView / NavigationStack。品牌 token（tokens.json → PPColor）只用于
/// 两件事：accent（`PPTone.accent`，全局 `.tint`）与含义色（safe / waiting / act，只在表达含义时用）。
/// 这里不写任何色值字面量（tools/ios/check-no-color-literals.sh 守门）。

/// 品牌字体：只有欢迎页标题这类品牌元素用 Newsreader；正文一律系统字体。
enum PPFont {
    /// 品牌字体的 PostScript 名（tools/ios/prepare-fonts.py 生成的字体文件，Info.plist UIAppFonts 注册）。
    static let faces = [
        "Newsreader-Regular", "Newsreader-Medium", "Newsreader-SemiBold",
        "Manrope-Regular", "Manrope-Medium", "Manrope-Bold",
    ]

    /// 随 Dynamic Type 缩放的品牌衬线字（`relativeTo` 决定缩放曲线）。
    static func brand(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("\(PPFontFamily.serif)-SemiBold", size: size, relativeTo: style)
    }
}

/// 品牌 accent 与含义色。深浅色各给一个值：浅色用 token，深色换成系统对应色，保证对比度。
enum PPTone {
    /// 品牌强调色：浅色 = 墨，深色 = 纸（反相），用于 `.tint`、主按钮底。
    static var accent: Color { adaptive(light: PPColor.ink, dark: PPColor.paper) }
    /// 压在 accent 上的文字色。
    static var onAccent: Color { adaptive(light: PPColor.paper, dark: PPColor.ink) }
    /// 含义：确认成功 / 已存好。
    static var safe: Color { adaptive(light: PPColor.safe, dark: Color(uiColor: .systemGreen)) }
    /// 含义：传输中 / 等待。
    static var waiting: Color { adaptive(light: PPColor.waiting, dark: Color(uiColor: .systemOrange)) }
    /// 含义：需要人处理。
    static var act: Color { adaptive(light: PPColor.act, dark: Color(uiColor: .systemRed)) }

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

/// 触感反馈。`sensoryFeedback` 是 iOS 17+，最低 iOS 16，所以直接用 UIKit 生成器（两个版本都可用）。
enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// 主 / 次 / 危险按钮。二选一的两个按钮用同一个组件、同一高度、等宽（tokens.json：二元选择同尺寸）。
/// 高度取系统 large 控件的 50pt，并随 Dynamic Type 增高（不再用旧 token 的 56）。
struct PPButton: View {
    enum Kind { case primary, secondary, danger }
    let title: String
    var kind: Kind = .primary
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 50)
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
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return PPTone.onAccent
        case .danger: return Color(uiColor: .white)
        case .secondary: return PPTone.accent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return PPTone.accent
        case .danger: return PPTone.act
        case .secondary: return Color(uiColor: .secondarySystemFill)
        }
    }
}

/// 居中的整屏提示（空态 / 加载态 / 错误态共用的形状）。
struct PPStateMessage: View {
    let text: String
    var symbol: String?
    var loading = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if loading {
                ProgressView()
            } else if let symbol {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            }
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 屏内浮出的短提示（保存成功 / 失败）：材质胶囊，约 2 秒自动消失。
struct PPToast: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
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

extension View {
    func ppToast(_ text: Binding<String?>) -> some View { modifier(PPToast(text: text)) }

    /// 列表行的含义色淡底（深浅色都成立），文字仍走系统语义色。
    func ppTinted(_ tone: Color?) -> some View { listRowBackground(tone.map { $0.opacity(0.12) }) }
}
