/**
 * JSON-LD builders (#691). Facts are read from the same sources the pages
 * render from — consts.ts and i18n/faq.ts — so a copy edit cannot leave the
 * structured data describing a different product.
 *
 * Only the platforms that actually ship are claimed: macOS, Windows, Android,
 * and iOS (App Store, or TestFlight in mainland China). Adding a platform
 * here before it ships would be a claim about the product that the product
 * cannot back up.
 */
import { BLUESKY_URL, GITHUB_URL, RELEASES_URL, SITE_DESCRIPTION, SITE_URL, YOUTUBE_URL } from './consts';
import { FAQ, FAQ_TITLE, faqAnswerText } from './i18n/faq';
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
    operatingSystem: 'macOS, Windows, Android, iOS',
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    license: 'https://www.gnu.org/licenses/agpl-3.0.html',
    downloadUrl: RELEASES_URL,
    sameAs: lang === 'zh' ? [GITHUB_URL] : [GITHUB_URL, BLUESKY_URL, YOUTUBE_URL],
  };
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
        acceptedAnswer: { '@type': 'Answer', text: faqAnswerText(item.a) },
      })),
    ),
  };
}

export function organization(): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    name: 'P-Pass',
    url: `${SITE_URL}/`,
    logo: `${SITE_URL}/icons/icon-carbon.svg`,
    sameAs: [GITHUB_URL, BLUESKY_URL, YOUTUBE_URL],
  };
}

export interface ArticleInput {
  lang: Lang;
  title: string;
  description: string;
  date: Date;
  path: string;
}

function postingSchema(type: 'BlogPosting' | 'Article', input: ArticleInput): JsonLd {
  const url = `${SITE_URL}${input.path}`;
  const org = {
    '@type': 'Organization',
    name: 'P-Pass',
    url: `${SITE_URL}/`,
  };
  return {
    '@context': 'https://schema.org',
    '@type': type,
    headline: input.title,
    description: input.description,
    datePublished: input.date.toISOString(),
    inLanguage: input.lang === 'zh' ? 'zh-CN' : 'en',
    mainEntityOfPage: { '@type': 'WebPage', '@id': url },
    url,
    author: org,
    publisher: {
      ...org,
      logo: {
        '@type': 'ImageObject',
        url: `${SITE_URL}/icons/icon-carbon.svg`,
      },
    },
    image: `${SITE_URL}/og-cover.png`,
  };
}

export function blogPosting(input: ArticleInput): JsonLd {
  return postingSchema('BlogPosting', input);
}

export function article(input: ArticleInput): JsonLd {
  return postingSchema('Article', input);
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
