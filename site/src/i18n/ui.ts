/**
 * Site copy — bilingual, same level. English is the default language (served
 * at /), Chinese mirrors at /zh/. Landing copy is canon (Brief §3): do not
 * reword; change only via the copy-review pipeline.
 */

export const LANGS = ['en', 'zh'] as const;
export type Lang = (typeof LANGS)[number];

export const ui = {
  en: {
    'nav.blog': 'Blog',
    'nav.faq': 'FAQ',
    'nav.lang': '中文',
    'hero.overline': "",
    'hero.h1': "Your family's photos, kept at home.",
    'hero.lede':
      "Photos from your phone back up automatically to the computer at home. No account, no cloud storage.",
    'hero.tagline': 'A self-hosted photo backup, without the server setup.',
    'hero.cta': 'Download P-Pass',
    'hero.cta.badge': 'Beta',
    'hero.cta.sub': "Mac with Apple silicon · 64-bit Windows · Android 8.0+",
    'hero.cta.mac': 'Download for Mac',
    'hero.cta.mac.sub': 'Apple silicon',
    'hero.cta.win': 'Download for Windows',
    'hero.cta.win.sub': '64-bit Windows',
    'hero.cta.android': 'Download for Android',
    'hero.cta.android.sub': 'Android 8.0+',
    'hero.cta.alt': 'All downloads and checksums on GitHub Releases',
    'hero.cta.ios': 'Install on iPhone',
    'hero.cta.ios.sub': 'Through TestFlight · iOS 16+',
    'hero.cta.win.note':
      'The Windows installer is not code-signed. If SmartScreen says "Windows protected your PC", choose More info, then Run anyway.',
    'hero.cta.iphone': 'iPhone (iOS 16 or later): install through TestFlight',
    'hero.cta.iphone.steps': 'How to install',
    'hero.cta.others': 'Also for:',
    'wechat.title': 'Open this page in your browser',
    'wechat.ios': 'WeChat can\'t install apps. Tap ··· at the top right and choose “Open in Safari”.',
    'wechat.android': 'WeChat can\'t download apps. Tap ··· at the top right and choose “Open in Browser”.',
    'wechat.close': 'OK',
    'video.label': 'P-Pass in 30 seconds',
    'video.fallback': "Your browser can't play this video.",
    'video.download': 'Download it (MP4)',
    'pillar1.title': "Set up once, and the whole family is backed up",
    'pillar1.body':
      "Uses a computer you already have at home. Connect each phone by scanning a code or entering a pairing code, then backups run automatically, with status always visible.",
    'pillar2.title': "End-to-end encrypted",
    'pillar2.body':
      "Photos are encrypted the whole way from phone to computer, on any network.",
    'pillar3.title': "Full-resolution originals",
    'pillar3.body':
      "Photos and videos are saved as the original files on your computer, never compressed, and open straight from the folder.",
    'footer.repo': 'GitHub · Open source (AGPL-3.0)',
    'footer.privacy': 'Privacy',
    'footer.terms': 'Terms',
    'footer.changelog': 'Changelog',
    'blog.h1': 'Blog',
    'blog.sub':
      "How we build P-Pass: design trade-offs and engineering notes on backing up phone photos to a computer at home.",
    'blog.empty': 'No posts yet.',
    'blog.description': "P-Pass blog: design trade-offs and engineering notes on family photo backup, including background backup and transfer reliability.",
    'post.back': '← Back to the blog',
  },
  zh: {
    'nav.blog': '博客',
    'nav.faq': '常见问题',
    'nav.lang': 'English',
    'hero.overline': '',
    'hero.h1': '全家的照片，存在自己家里。',
    'hero.lede':
      '手机照片自动备份到家中的电脑。无需注册账号，不使用云存储。',
    'hero.tagline': '',
    'hero.cta': '下载 P-Pass',
    'hero.cta.badge': 'Beta',
    'hero.cta.sub': 'Apple 芯片 Mac · 64 位 Windows · Android 8.0+',
    'hero.cta.mac': '下载 Mac 版',
    'hero.cta.mac.sub': 'Apple 芯片',
    'hero.cta.win': '下载 Windows 版',
    'hero.cta.win.sub': '64 位 Windows',
    'hero.cta.android': '下载 Android 版',
    'hero.cta.android.sub': 'Android 8.0+',
    'hero.cta.alt': '也可以从 GitHub Releases 下载',
    'hero.cta.ios': '安装 iPhone 版',
    'hero.cta.ios.sub': '通过 TestFlight · iOS 16+',
    'hero.cta.win.note':
      'Windows 安装包未做代码签名。安装时如果出现「Windows 已保护你的电脑」，点「更多信息」，再点「仍要运行」。',
    'hero.cta.iphone': 'iPhone（iOS 16 及以上）通过 TestFlight 安装',
    'hero.cta.iphone.steps': '安装步骤',
    'hero.cta.others': '其他平台：',
    'wechat.title': '请在浏览器中打开本页',
    'wechat.ios': '微信内无法安装。点右上角「···」，选择「在 Safari 中打开」。',
    'wechat.android': '微信内无法下载。点右上角「···」，选择「在浏览器中打开」。',
    'wechat.close': '知道了',
    'video.label': '30 秒了解 P-Pass',
    'video.fallback': '你的浏览器无法播放这段视频。',
    'video.download': '下载观看（MP4）',
    'pillar1.title': '一次设置，全家自动备份',
    'pillar1.body':
      '用家里已有的电脑。每部手机扫码或输入配对码连接，之后自动备份，状态随时可见。',
    'pillar2.title': '端到端加密',
    'pillar2.body':
      '无论在什么网络下，照片都全程加密传输。',
    'pillar3.title': '原图保存，不压缩',
    'pillar3.body':
      '照片和视频以原始文件存放在家中电脑，在目录中即可直接打开。',
    'footer.repo': 'GitHub 仓库 · AGPL-3.0 开源',
    'footer.privacy': '隐私政策',
    'footer.terms': '使用条款',
    'footer.changelog': '更新日志',
    'blog.h1': '博客',
    'blog.sub': 'P-Pass 的设计取舍与开发记录：怎样把手机照片可靠地备份到家里的电脑。',
    'blog.empty': '暂无文章。',
    'blog.description': 'P-Pass 博客：家庭照片备份的设计取舍，以及后台备份、传输可靠性等开发记录。',
    'post.back': '← 返回博客',
  },
} as const;

export type UiKey = keyof (typeof ui)['en'];

export function t(lang: Lang, key: UiKey): string {
  return ui[lang][key] ?? ui.en[key];
}
