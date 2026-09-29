/**
 * Site copy — bilingual, same level. English is the default language (served
 * at /), Chinese mirrors at /zh/. Landing copy is canon (Brief §3): do not
 * reword; change only via the copy-review pipeline.
 */

export const LANGS = ['en', 'zh'] as const;
export type Lang = (typeof LANGS)[number];

export const ui = {
  en: {
    'meta.title': "P-Pass — Your family's photos, at home",
    'meta.description':
      "P2P photo backup for families: phones back up to your own computer at home — through no one else's cloud. Open source, end-to-end encrypted.",
    'nav.blog': 'Blog',
    'nav.lang': '中文',
    'hero.overline': 'P2P photo backup for families',
    'hero.h1': "Your family's photos, at home. Literally.",
    'hero.lede':
      'Photos on your phone back up automatically to the computer in your home. No account to sign up for, and nothing goes to any cloud drive.',
    'hero.cta': 'Download P-Pass',
    'hero.cta.badge': 'Beta',
    'hero.cta.sub': 'macOS / Android · GitHub Releases',
    'video.label': 'P-Pass in 30 seconds',
    'video.fallback': "Your browser can't play this video.",
    'video.download': 'Download it (MP4)',
    'pillar1.title': 'Photos come home',
    'pillar1.body':
      "Phones back up automatically to your own computer, through no one else's cloud. Originals live at your house; the index can always be rebuilt from them.",
    'pillar2.title': 'Designed for the 60-year-old in the family',
    'pillar2.body':
      'Scan one code, then never think about it again. Open the app and get a straight answer to "are my photos safe?"',
    'pillar3.title': 'Open source · End-to-end encrypted',
    'pillar3.body':
      'The relay only forwards ciphertext, never stored, never decrypted. Photos never touch a server — ours included.',
    'footer.repo': 'GitHub repository',
    'footer.privacy': 'Privacy',
    'footer.terms': 'Terms',
    'footer.changelog': 'Changelog',
    'blog.h1': 'Blog',
    'blog.sub':
      'Product thinking, design decisions, build logs — written as it happened, not as marketing.',
    'blog.empty': 'The first post is on its way.',
    'blog.description': 'P-Pass development notes — product, design, and engineering.',
    'post.back': '← Back to the blog',
  },
  zh: {
    'meta.title': 'P-Pass — 家人的照片，备份回自己家',
    'meta.description':
      'P2P 家庭照片备份：手机自动备份到家里自己的电脑，不经过任何人的云。开源、端到端加密。',
    'nav.blog': '博客',
    'nav.lang': 'English',
    'hero.overline': '',
    'hero.h1': '全家的照片，存在自己家里。',
    'hero.lede':
      '手机照片自动备份到家中的电脑，无需注册账号，不上传任何云端。',
    'hero.cta': '下载 P-Pass',
    'hero.cta.badge': 'Beta',
    'hero.cta.sub': 'Apple 芯片 Mac · Android 8.0+',
    'video.label': '30 秒看懂 P-Pass',
    'video.fallback': '你的浏览器无法播放这段视频。',
    'video.download': '下载观看（MP4）',
    'pillar1.title': '一次设置，全家自动备份',
    'pillar1.body':
      '家中闲置的电脑即可安装。手机扫码后自动备份，状态随时可见。',
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
    'blog.empty': '第一篇在路上。',
    'blog.description': 'P-Pass 博客：家庭照片备份的设计取舍，以及 Android 后台备份、传输可靠性等开发记录。',
    'post.back': '← 返回博客',
  },
} as const;

export type UiKey = keyof (typeof ui)['en'];

export function t(lang: Lang, key: UiKey): string {
  return ui[lang][key] ?? ui.en[key];
}
