import type { Lang } from './i18n/ui';

export const SITE_URL = 'https://p-pass.hawkeye-xb.com';
export const GITHUB_URL = 'https://github.com/hawkeye-xb/P-Pass';
export const RELEASES_URL = `${GITHUB_URL}/releases/latest`;

// Canon copy (Brief §3) — one entry per language, same level.
export const SITE_TITLE: Record<Lang, string> = {
  en: "P-Pass — Your family's photos, kept at home",
  zh: 'P-Pass — 全家的照片，存在自己家里',
};

export const SITE_DESCRIPTION: Record<Lang, string> = {
  en: 'Photo backup for families: your phone backs up automatically to the computer at home. No account, no cloud storage. Open source and end-to-end encrypted.',
  zh: '家庭照片备份：手机照片自动备份到家中的电脑，无需注册账号，不上传任何云端。开源，端到端加密。',
};
