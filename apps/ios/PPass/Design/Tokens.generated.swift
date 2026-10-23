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

/// 手机首页语义尺寸（tokens.json mobile-ui）。基础值 = Android；iOS 偏离登记在 platforms.ios（见 iosOverrides）。
/// 值为 system 的项不生成常量：那一项用原生 List 的默认值，代码里不要再写数字。
enum PPUI {
    /// 字号（pt）
    enum TextSize {
        /// iOS 覆盖（Android 15px）：见 iosOverrides["mobile-ui.type.row-label"]
        static let rowLabel: CGFloat = 17
        /// iOS 覆盖（Android 14px）：见 iosOverrides["mobile-ui.type.row-value"]
        static let rowValue: CGFloat = 15
        /// iOS 覆盖（Android 12px）：见 iosOverrides["mobile-ui.type.row-hint"]
        static let rowHint: CGFloat = 13
        /// iOS 覆盖（Android 16px）：见 iosOverrides["mobile-ui.type.card-title"]
        static let cardTitle: CGFloat = 17
        /// iOS 覆盖（Android 14px）：见 iosOverrides["mobile-ui.type.card-body"]
        static let cardBody: CGFloat = 17
        static let heroNumber: CGFloat = 40
        static let heroOfN: CGFloat = 18
        /// iOS 覆盖（Android 14px）：见 iosOverrides["mobile-ui.type.hero-meta"]
        static let heroMeta: CGFloat = 15
        static let statusLine: CGFloat = 13.5
        static let detailToggle: CGFloat = 13
        static let pairTitle: CGFloat = 30
        /// iOS 覆盖（Android 22px）：见 iosOverrides["mobile-ui.type.pair-name"]
        static let pairName: CGFloat = 24
        /// iOS 覆盖（Android 14px）：见 iosOverrides["mobile-ui.type.pair-label"]
        static let pairLabel: CGFloat = 12
        /// iOS 覆盖（Android 14px）：见 iosOverrides["mobile-ui.type.pair-fingerprint"]
        static let pairFingerprint: CGFloat = 13
        static let pairBody: CGFloat = 17
    }

    /// 间距 / 尺寸（pt）
    enum Layout {
        /// iOS 覆盖（Android 20px）：见 iosOverrides["mobile-ui.layout.page-gutter"]
        // pageGutter: system（原生默认，不生成常量）
        static let pageTop: CGFloat = 14
        static let cardGap: CGFloat = 18
        /// iOS 覆盖（Android 20px）：见 iosOverrides["mobile-ui.layout.card-padding"]
        // cardPadding: system（原生默认，不生成常量）
        static let rowMinHeight: CGFloat = 52
        static let heroOfNGap: CGFloat = 6
        static let heroDividerAbove: CGFloat = 14
        static let heroDividerBelow: CGFloat = 12
        static let chipPaddingX: CGFloat = 18
    }

    /// 底色
    enum Surface {
        /// iOS 覆盖（Android paper）：见 iosOverrides["mobile-ui.surface.settings-card"]
        static let settingsCard = PPColor.linen
    }

    /// platforms.ios 的全部覆盖：键 → (Android 基础值, iOS 值, 理由)。
    static let iosOverrides: [String: (android: String, ios: String, why: String)] = [
        "mobile-ui.type.row-label": ("15px", "17px", "iOS 字号以系统文字样式为基准、随动态字号缩放（body 17 / subheadline 15 / footnote 13），与系统「设置」App 一致；照搬 Android 的 15/14 在 iOS 上偏小，也不跟系统同步。"),
        "mobile-ui.type.row-value": ("14px", "15px", "iOS 字号以系统文字样式为基准、随动态字号缩放（body 17 / subheadline 15 / footnote 13），与系统「设置」App 一致；照搬 Android 的 15/14 在 iOS 上偏小，也不跟系统同步。"),
        "mobile-ui.type.row-hint": ("12px", "13px", "iOS 字号以系统文字样式为基准、随动态字号缩放（body 17 / subheadline 15 / footnote 13），与系统「设置」App 一致；照搬 Android 的 15/14 在 iOS 上偏小，也不跟系统同步。"),
        "mobile-ui.type.card-title": ("16px", "17px", "iOS 字号以系统文字样式为基准、随动态字号缩放（body 17 / subheadline 15 / footnote 13），与系统「设置」App 一致；照搬 Android 的 15/14 在 iOS 上偏小，也不跟系统同步。标题取 headline 档（17 粗体）。"),
        "mobile-ui.type.card-body": ("14px", "17px", "iOS 字号以系统文字样式为基准、随动态字号缩放（body 17 / subheadline 15 / footnote 13），与系统「设置」App 一致；照搬 Android 的 15/14 在 iOS 上偏小，也不跟系统同步。"),
        "mobile-ui.type.hero-meta": ("14px", "15px", "iOS 字号以系统文字样式为基准、随动态字号缩放（body 17 / subheadline 15 / footnote 13），与系统「设置」App 一致；照搬 Android 的 15/14 在 iOS 上偏小，也不跟系统同步。"),
        "mobile-ui.type.pair-name": ("22px", "24px", "iOS 核对页只用 PPFont 现成语义样式、不另写字号：电脑名取 PPFont.title3（衬线 24，随 title3 缩放）；Android 是无衬线粗体 22。层级不变：标题 > 电脑名 > 说明 > 指纹。"),
        "mobile-ui.type.pair-label": ("14px", "12px", "iOS 核对页只用 PPFont 现成语义样式：小标签取 PPFont.captionBold（12，随 caption 缩放）；Android 是 14。"),
        "mobile-ui.type.pair-fingerprint": ("14px", "13px", "iOS 核对页只用 PPFont 现成语义样式：指纹取 PPFont.monoSmall（系统等宽 footnote 档 13，随系统字号缩放）；Android 是 14 等宽。"),
        "mobile-ui.layout.page-gutter": ("20px", "system", "原生 insetGrouped 的分组边距（iPhone 16 / iOS 26 实测 16pt），与系统「设置」App 一致；改成 20 要覆盖系统布局，没有收益。"),
        "mobile-ui.layout.card-padding": ("20px", "system", "英雄卡是 List 的一行，内边距由系统行距决定（实测左右 16、上下约 17–21，差 1–4pt）；硬设 20 要和系统最小行高较劲。"),
        "mobile-ui.surface.settings-card": ("paper", "linen", "insetGrouped 的分组画不了 1px 描边，paper 底放在 paper 页面上看不出卡片边界，改用 linen（内嵌卡片色）。"),
    ]
}

/// 品牌字体族（字体栈里的第一个）。字体文件随 App 捆绑。
enum PPFontFamily {
    static let serif = "Newsreader"
    static let sans = "Manrope"
}
