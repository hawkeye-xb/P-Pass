import SwiftUI

/// 语义组件（#315 / #344）。颜色只用 PPColor（由 tokens.json 生成），字号守 tokens.json rules：
/// 手机正文 ≥17、点击区 ≥56。对位 Android ui/Tokens.kt + 各屏里的按钮写法。
enum PPFont {
    /// 品牌字体的 PostScript 名（tools/ios/prepare-fonts.py 生成的字体文件，Info.plist UIAppFonts 注册）。
    static let faces = [
        "Newsreader-Regular", "Newsreader-Medium", "Newsreader-SemiBold",
        "Manrope-Regular", "Manrope-Medium", "Manrope-Bold",
    ]

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face = weight == .semibold ? "SemiBold" : (weight == .medium ? "Medium" : "Regular")
        return .custom("\(PPFontFamily.serif)-\(face)", size: size)
    }

    static func sans(_ size: CGFloat = PPSize.bodyMin, _ weight: Font.Weight = .regular) -> Font {
        let face = weight == .bold || weight == .semibold ? "Bold" : (weight == .medium ? "Medium" : "Regular")
        return .custom("\(PPFontFamily.sans)-\(face)", size: size)
    }

    static var body: Font { sans(PPSize.bodyMin) }
    static var caption: Font { sans(15) }
    static var headline: Font { serif(PPSize.headlineMin) }
}

/// 主/次按钮。二选一的两个按钮用同一个组件、同一高度、等宽（tokens.json：二元选择同尺寸）。
struct PPButton: View {
    enum Kind { case primary, secondary, danger }
    let title: String
    var kind: Kind = .primary
    var height: CGFloat = PPSize.tapMin
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PPFont.sans(PPSize.bodyMin, .bold))
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: PPRadius.controlMobile))
                .overlay(
                    RoundedRectangle(cornerRadius: PPRadius.controlMobile)
                        .stroke(kind == .secondary ? PPColor.borderStrong : PPColor.paper.opacity(0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: return PPColor.paper
        case .secondary: return PPColor.ink60
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return PPColor.ink
        case .danger: return PPColor.act
        case .secondary: return PPColor.paper
        }
    }
}

/// 卡片底。
struct PPCard<Content: View>: View {
    var fill: Color = PPColor.linen
    var stroke: Color = PPColor.border
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: PPRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PPRadius.card).stroke(stroke, lineWidth: 1))
    }
}

/// 居中的整屏提示（空态 / 加载态 / 错误态共用的形状）。
struct PPStateMessage: View {
    let text: String
    var loading = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if loading { ProgressView().tint(PPColor.ink60) }
            Text(text)
                .font(PPFont.body)
                .foregroundStyle(PPColor.ink60)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                PPButton(title: actionTitle, kind: .secondary, action: action).frame(maxWidth: 240)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// 整页底色 + 默认前景色（不让系统 label 色漏进来）。
    func ppScreen(_ fill: Color = PPColor.paper) -> some View {
        self.foregroundStyle(PPColor.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(fill.ignoresSafeArea())
    }
}
