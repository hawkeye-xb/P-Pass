// 由 tools/ios/gen-tokens.py 从 assets/design/tokens.json 生成——不要手改。
// 改 token：先改 tokens.json，再跑 `just ios-tokens`（或 python3 tools/ios/gen-tokens.py）。
// 漂移门禁：gen-tokens.py --check（逐字节）+ PPassTests/DesignTokensTests（逐键对照源文件）。
// swiftlint:disable all
import SwiftUI

/// tokens.json 里的原始写法。DesignTokensTests 拿它与源文件逐键比较。
enum PPTokenSource {
    static let colors: [String: String] = [
        "paper": "#FBF8F2",
        "canvas": "#EFE9DF",
        "linen": "#F1ECE3",
        "ink": "#171512",
        "ink-hover": "#2A2621",
        "ink-60": "#4A453E",
        "ink-40": "#6B655C",
        "hairline": "#E0D8CB",
        "surface-dark": "#211E1A",
        "safe": "#2E6B4F",
        "safe-bg": "#E4F1E8",
        "waiting": "#C9761E",
        "waiting-bg": "#F7EBDA",
        "act": "#B5341F",
        "act-bg": "#F7E2DE",
        "idle": "#8A857C",
        "idle-bg": "#EDE8DF",
        "border": "rgba(23,21,18,.12)",
        "border-strong": "rgba(23,21,18,.24)",
        "divider": "rgba(23,21,18,.10)",
    ]
    static let radii: [String: String] = [
        "card": "20px",
        "control": "14px",
        "control-sm": "12px",
        "control-mobile": "20px",
        "pill": "999px",
    ]
    static let mobileSizes: [String: String] = [
        "body-min": "17px",
        "tap-min": "56px",
        "headline": "30px–52px",
    ]
    static let fonts: [String: String] = [
        "serif": "'Newsreader', Georgia, 'Times New Roman', serif",
        "sans": "'Manrope', 'Noto Sans SC', -apple-system, 'PingFang SC', 'Segoe UI', ui-sans-serif, system-ui, sans-serif",
    ]
}

/// 颜色。只有 safe / waiting / act 三种含义色（tokens.json rules）。
enum PPColor {
    /// app surface 界面底色
    static let paper = Color(.sRGB, red: 251 / 255, green: 248 / 255, blue: 242 / 255, opacity: 1)
    /// board / behind cards 卡片外底色
    static let canvas = Color(.sRGB, red: 239 / 255, green: 233 / 255, blue: 223 / 255, opacity: 1)
    /// inset card / secondary surface 内嵌卡片
    static let linen = Color(.sRGB, red: 241 / 255, green: 236 / 255, blue: 227 / 255, opacity: 1)
    /// text, primary button 文字与主按钮
    static let ink = Color(.sRGB, red: 23 / 255, green: 21 / 255, blue: 18 / 255, opacity: 1)
    /// primary button hover 主按钮悬停
    static let inkHover = Color(.sRGB, red: 42 / 255, green: 38 / 255, blue: 33 / 255, opacity: 1)
    /// secondary text / Chinese line 次级文字与中文行
    static let ink60 = Color(.sRGB, red: 74 / 255, green: 69 / 255, blue: 62 / 255, opacity: 1)
    /// meta / captions 辅助说明
    static let ink40 = Color(.sRGB, red: 107 / 255, green: 101 / 255, blue: 92 / 255, opacity: 1)
    /// progress track, dividers on linen 分隔线
    static let hairline = Color(.sRGB, red: 224 / 255, green: 216 / 255, blue: 203 / 255, opacity: 1)
    /// camera / photo viewer background 扫码与看图背景
    static let surfaceDark = Color(.sRGB, red: 33 / 255, green: 30 / 255, blue: 26 / 255, opacity: 1)
    /// MEANING: confirmed success / safely stored 含义色：确认成功/已存好
    static let safe = Color(.sRGB, red: 46 / 255, green: 107 / 255, blue: 79 / 255, opacity: 1)
    /// safe pill background 安全胶囊底
    static let safeBg = Color(.sRGB, red: 228 / 255, green: 241 / 255, blue: 232 / 255, opacity: 1)
    /// MEANING: in progress / slower route 含义色：传输中/中继
    static let waiting = Color(.sRGB, red: 201 / 255, green: 118 / 255, blue: 30 / 255, opacity: 1)
    /// waiting pill background 等待胶囊底
    static let waitingBg = Color(.sRGB, red: 247 / 255, green: 235 / 255, blue: 218 / 255, opacity: 1)
    /// MEANING: a person must act 含义色：需要人处理
    static let act = Color(.sRGB, red: 181 / 255, green: 52 / 255, blue: 31 / 255, opacity: 1)
    /// act pill background 处理胶囊底
    static let actBg = Color(.sRGB, red: 247 / 255, green: 226 / 255, blue: 222 / 255, opacity: 1)
    /// neutral waiting (offline peer) 中性等待
    static let idle = Color(.sRGB, red: 138 / 255, green: 133 / 255, blue: 124 / 255, opacity: 1)
    /// idle pill background 中性胶囊底
    static let idleBg = Color(.sRGB, red: 237 / 255, green: 232 / 255, blue: 223 / 255, opacity: 1)
    /// card borders 卡片描边
    static let border = Color(.sRGB, red: 23 / 255, green: 21 / 255, blue: 18 / 255, opacity: 0.12)
    /// secondary button borders 次级按钮描边
    static let borderStrong = Color(.sRGB, red: 23 / 255, green: 21 / 255, blue: 18 / 255, opacity: 0.24)
    /// row dividers 行分隔
    static let divider = Color(.sRGB, red: 23 / 255, green: 21 / 255, blue: 18 / 255, opacity: 0.1)

    /// 按 tokens.json 的键索引，供测试核对生成结果。
    static let all: [String: Color] = [
        "paper": paper,
        "canvas": canvas,
        "linen": linen,
        "ink": ink,
        "ink-hover": inkHover,
        "ink-60": ink60,
        "ink-40": ink40,
        "hairline": hairline,
        "surface-dark": surfaceDark,
        "safe": safe,
        "safe-bg": safeBg,
        "waiting": waiting,
        "waiting-bg": waitingBg,
        "act": act,
        "act-bg": actBg,
        "idle": idle,
        "idle-bg": idleBg,
        "border": border,
        "border-strong": borderStrong,
        "divider": divider,
    ]
}

/// 圆角（pt）。
enum PPRadius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
    static let controlSm: CGFloat = 12
    static let controlMobile: CGFloat = 20
    static let pill: CGFloat = 999
}

/// 手机尺寸（pt）。区间拆成 Min/Max。
enum PPSize {
    static let bodyMin: CGFloat = 17
    static let tapMin: CGFloat = 56
    static let headlineMin: CGFloat = 30
    static let headlineMax: CGFloat = 52
}

/// 品牌字体族（字体栈里的第一个）。字体文件随 App 捆绑。
enum PPFontFamily {
    static let serif = "Newsreader"
    static let sans = "Manrope"
}
