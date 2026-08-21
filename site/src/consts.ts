import type { Lang } from './i18n/ui';

export const SITE_URL = 'https://p-pass.hawkeye-xb.com';
export const GITHUB_URL = 'https://github.com/hawkeye-xb/P-Pass';
export const RELEASES_URL = `${GITHUB_URL}/releases/latest`;

// Canon copy (Brief §3) — one entry per language, same level.
export const SITE_TITLE: Record<Lang, string> = {
  en: "P-Pass — Your family's photos, at home",
  zh: 'P-Pass — 家人的照片，备份回自己家',
};

export const SITE_DESCRIPTION: Record<Lang, string> = {
  en: "P2P photo backup for families: phones back up to your own computer at home — through no one else's cloud. Open source, end-to-end encrypted.",
  zh: 'P2P 家庭照片备份：手机自动备份到家里自己的电脑，不经过任何人的云。开源、端到端加密。',
};
