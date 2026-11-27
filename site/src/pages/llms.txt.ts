import { getCollection } from 'astro:content';
import {
  APP_STORE_URL,
  GITHUB_URL,
  MIRROR_ANDROID,
  MIRROR_MAC,
  MIRROR_WINDOWS,
  RELEASES_URL,
  SITE_DESCRIPTION,
  SITE_URL,
  TESTFLIGHT_URL,
} from '../consts';
import { FAQ, faqAnswerText } from '../i18n/faq';
import { ui } from '../i18n/ui';

export async function GET() {
  const faqById = new Map(
    FAQ.en.flatMap((group) => group.items.map((item) => [item.id, item] as const)),
  );
  const faqText = (id: string) => {
    const item = faqById.get(id);
    if (!item) {
      throw new Error(`Missing FAQ item in llms.txt generator: ${id}`);
    }
    return faqAnswerText(item.a);
  };

  const guides = (await getCollection('guides', ({ data }) => !data.draft)).sort((a, b) => {
    const dateDiff = b.data.date.valueOf() - a.data.date.valueOf();
    if (dateDiff !== 0) return dateDiff;
    return a.data.lang === b.data.lang ? 0 : a.data.lang === 'en' ? -1 : 1;
  });

  const guideLines = guides.map((guide) => {
    const url =
      guide.data.lang === 'en'
        ? `${SITE_URL}/guides/${guide.id.replace(/-en$/, '')}/`
        : `${SITE_URL}/zh/guides/${guide.id}/`;
    const desc = guide.data.description ? `: ${guide.data.description}` : '';
    return `- [${guide.data.title}](${url})${desc}`;
  });

  const lines = [
    '# P-Pass',
    '',
    `> ${SITE_DESCRIPTION.en} ${ui.en['pillar3.body']}`,
    '',
    '## What it does',
    '',
    `- ${ui.en['pillar1.title']}: ${ui.en['pillar1.body']}`,
    `- ${ui.en['pillar2.title']}: ${ui.en['pillar2.body']}`,
    `- ${ui.en['pillar3.title']}: ${ui.en['pillar3.body']}`,
    `- Data path: ${faqText('where-photos-go')}`,
    `- One-way backup: ${faqText('phone-delete')}`,
    `- Cost and license: ${faqText('cost')}`,
    '',
    '## Supported platforms and boundaries',
    '',
    `- Supported platforms: ${ui.en['hero.cta.sub']}.`,
    `- Platform details: ${faqText('supported-devices')}`,
    `- Windows installer note: ${ui.en['hero.cta.win.note']}`,
    `- Network & battery: ${faqText('mobile-data')}`,
    `- Computer requirement: ${faqText('computer-on')}`,
    '',
    '## Pages',
    '',
    `- Home (English): ${SITE_URL}/`,
    `- 首页（中文）: ${SITE_URL}/zh/`,
    `- Guides (English): ${SITE_URL}/guides/`,
    `- 使用指南（中文）: ${SITE_URL}/zh/guides/`,
    `- FAQ (English): ${SITE_URL}/faq/`,
    `- 常见问题（中文）: ${SITE_URL}/zh/faq/`,
    `- Blog (English): ${SITE_URL}/blog/`,
    `- 博客（中文）: ${SITE_URL}/zh/blog/`,
    `- Privacy (English): ${SITE_URL}/privacy/`,
    `- 隐私政策（中文）: ${SITE_URL}/zh/privacy/`,
    `- Terms (English): ${SITE_URL}/terms/`,
    `- 使用条款（中文）: ${SITE_URL}/zh/terms/`,
    '',
    '## Guides',
    '',
    ...(guideLines.length > 0 ? guideLines : ['- No guides published yet.']),
    '',
    '## Downloads',
    '',
    `- Download page (all platforms): ${SITE_URL}`,
    `- Download page (中文): ${SITE_URL}/zh/`,
    `- macOS (Apple silicon): ${MIRROR_MAC}`,
    `- Windows (64-bit): ${MIRROR_WINDOWS}`,
    `- Android (8.0+): ${MIRROR_ANDROID}`,
    `- iPhone (App Store): ${APP_STORE_URL}`,
    `- iPhone (TestFlight, mainland China): ${TESTFLIGHT_URL}`,
    `- GitHub Releases (all builds and checksums): ${RELEASES_URL}`,
    `- Source repository (AGPL-3.0): ${GITHUB_URL}`,
    '',
    '## Languages',
    '',
    '- English is served at the root (/); Chinese is mirrored under /zh/.',
    '',
  ];

  return new Response(lines.join('\n'), {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
    },
  });
}
