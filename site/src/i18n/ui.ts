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
      'Phone photos back up automatically to the computer in your home. No cloud, no account — devices talk directly, with a relay only as fallback. Backing up at home is free, forever.',
    'hero.cta': 'Download P-Pass',
    'hero.cta.sub': 'macOS / Android · GitHub Releases',
    'hero.icon.alt': 'P-Pass roof-guardian icon',
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
    'privacy.h2': "Privacy is not a feature. It's a stance.",
    'privacy.body':
      "Your photos never leave home: bytes, thumbnails, filenames, and the timeline move only between your family's devices, and the relay forwards ciphertext and nothing more. That floor is guaranteed by architecture — open source, so you can verify it. Above that floor, collection is planned and bounded: this site gathers only the aggregate numbers a commercial product needs (like download counts); the app sends crash reports only when you choose to, and the current build collects none. What's collected and what's never touched is always written down, in the open.",
    closing: 'No cloud. No account. No us.',
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
      '家人的照片自动备份到你家电脑。没有云，没有账号——设备之间直接传输，中继只做转发兜底。回家备份，永远免费。',
    'hero.cta': '下载 P-Pass',
    'hero.cta.sub': 'macOS / Android · GitHub Releases',
    'hero.icon.alt': 'P-Pass 屋脊兽图标',
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
    'privacy.h2': '隐私不是功能，是立场',
    'privacy.body':
      '照片本身永远不出门：字节、缩略图、文件名、时间线只在你家的设备之间走，中继只转发密文——这条由架构保证，开源可验证。底线之上，收集是有规划、有边界的：官网只统计商业化必需的汇总数据（如下载量）；客户端崩溃信息只在你主动反馈时按需收集，当前版本不收集。收集什么、不收集什么，永远写在明处。',
    closing: '照片只在你家的设备之间走——没有云，没有账号，也没有「我们」。',
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
