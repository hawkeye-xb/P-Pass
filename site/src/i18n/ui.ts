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
    'hero.cta.sub': 'macOS / Android · GitHub Releases',
    'hero.icon.alt': 'P-Pass roof-guardian icon',
    'video.label': 'P-Pass in 30 seconds',
    'video.fallback': "Your browser can't play this video.",
    'video.download': 'Download it (MP4)',
    'testing.note':
      "P-Pass is in testing. Windows desktop and iPhone are on the way; iOS limits background backup, so the iPhone experience will differ — we'll spell that out when it ships.",
    'pillar1.title': 'Photos come home',
    'pillar1.body':
      "Phones back up automatically to your own computer, through no one else's cloud. Originals live at your house; the index can always be rebuilt from them.",
    'pillar2.title': 'Designed for the 60-year-old in the family',
    'pillar2.body':
      'Scan one code, then never think about it again. Open the app and get a straight answer to "are my photos safe?"',
    'pillar3.title': 'Open source · End-to-end encrypted',
    'pillar3.body':
      'The relay only forwards ciphertext, never stored, never decrypted. Photos never touch a server — ours included.',
    'build.title': 'For the one who installs it',
    'build.body':
      'Open source, AGPL-3.0. Originals stay plain files on your own disk; the index rebuilds from them.',
    'build.link': 'The code lives on GitHub',
    'privacy.h2': 'What we collect',
    'privacy.body':
      "This site keeps count of things like downloads, because we need to know if anyone's actually using it. The app itself sends nothing today; if a crash log would ever help fix something, it'll ask you first.",
    'footer.tag':
      'P-Pass — photo backup for families. Open source, end-to-end encrypted. Photos never leave home.',
    'footer.repo': 'GitHub repository',
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
    'hero.overline': 'P2P 家庭照片备份',
    'hero.h1': '全家的照片，住回自己家。',
    'hero.lede':
      '手机里的照片会自动备份到你家的电脑上，不用注册账号，也不传到任何云盘。',
    'hero.cta': '下载 P-Pass',
    'hero.cta.sub': 'macOS / Android · GitHub Releases',
    'hero.icon.alt': 'P-Pass 屋脊兽图标',
    'video.label': '30 秒看懂 P-Pass',
    'video.fallback': '你的浏览器无法播放这段视频。',
    'video.download': '下载观看（MP4）',
    'testing.note':
      '目前是测试阶段——Windows 桌面版与 iPhone 版在路上；iPhone 受 iOS 系统限制，后台自动备份体验会不同，发布时会说清楚。',
    'pillar1.title': '照片回家',
    'pillar1.body':
      '手机自动备份到家里自己的电脑——不经过任何人的云。原图在你家，索引随时能从原图重建。',
    'pillar2.title': '为 60 岁的家人设计',
    'pillar2.body':
      '拿到手机，扫一次码，之后什么都不用做。打开 App 就能得到「照片安全吗」的真话。',
    'pillar3.title': '开源 · 端到端加密',
    'pillar3.body':
      '中继只转发密文、不落盘、不解密。照片不经过任何服务器——包括我们的。',
    'build.title': '给装机的你',
    'build.body':
      '开源（AGPL-3.0）。原图以裸文件存在你自己的硬盘上，索引随时可重建。',
    'build.link': '代码在 GitHub 上',
    'privacy.h2': '我们收集什么',
    'privacy.body':
      '官网会统计下载量这类汇总数字，做产品总得知道有没有人在用。App 目前什么都不上报；哪天真需要你发一份崩溃日志，会先问过你。',
    'footer.tag': 'P-Pass — 家人照片备份。开源，端到端加密，照片不出门。',
    'footer.repo': 'GitHub 仓库',
    'blog.h1': '博客',
    'blog.sub': '产品想法、设计决策、开发过程——写真实过程，不写营销稿。',
    'blog.empty': '第一篇在路上。',
    'blog.description': 'P-Pass 的开发过程、产品设计与踩坑记录。',
    'post.back': '← 返回博客',
  },
} as const;

export type UiKey = keyof (typeof ui)['en'];

export function t(lang: Lang, key: UiKey): string {
  return ui[lang][key] ?? ui.en[key];
}
