/**
 * JSON-LD builders (#691). Facts are read from the same sources the pages
 * render from — consts.ts and i18n/faq.ts — so a copy edit cannot leave the
 * structured data describing a different product.
 *
 * Only the platforms that actually ship are claimed: macOS and Android.
 * Windows and iOS are still in progress, and saying otherwise in structured
 * data would be a claim about the product that the product cannot back up.
 */
import { GITHUB_URL, RELEASES_URL, SITE_DESCRIPTION, SITE_URL } from './consts';
import { FAQ, FAQ_TITLE } from './i18n/faq';
import type { FaqBlock } from './i18n/faq';
import type { Lang } from './i18n/ui';

export interface JsonLd {
  '@context': string;
  '@type': string;
  [key: string]: unknown;
}

export function softwareApplication(lang: Lang): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: 'P-Pass',
    description: SITE_DESCRIPTION[lang],
    url: lang === 'zh' ? `${SITE_URL}/zh/` : `${SITE_URL}/`,
    applicationCategory: 'MultimediaApplication',
    operatingSystem: 'macOS, Android',
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    license: 'https://www.gnu.org/licenses/agpl-3.0.html',
    downloadUrl: RELEASES_URL,
    sameAs: [GITHUB_URL],
  };
}

/** Answer text for one FAQ item: paragraphs and lists flattened, as schema.org expects a string. */
function answerText(blocks: FaqBlock[]): string {
  return blocks.map((block) => (typeof block === 'string' ? block : block.list.join(' '))).join(' ');
}

export function faqPage(lang: Lang): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    name: FAQ_TITLE[lang],
    mainEntity: FAQ[lang].flatMap((group) =>
      group.items.map((item) => ({
        '@type': 'Question',
        name: item.q,
        acceptedAnswer: { '@type': 'Answer', text: answerText(item.a) },
      })),
    ),
  };
}

export function breadcrumb(trail: { name: string; path: string }[]): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: trail.map((step, index) => ({
      '@type': 'ListItem',
      position: index + 1,
      name: step.name,
      item: `${SITE_URL}${step.path}`,
    })),
  };
}
