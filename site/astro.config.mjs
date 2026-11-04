// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://p-pass.hawkeye-xb.com',
  integrations: [
    // The sitemap is derived from the route table at build time (#691): a
    // hand-maintained file drifts out of sync every time a page is added.
    sitemap({
      i18n: {
        defaultLocale: 'en',
        locales: { en: 'en', zh: 'zh-CN' },
      },
    }),
  ],
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'zh'],
    routing: {
      prefixDefaultLocale: false,
    },
  },
  markdown: {
    shikiConfig: {
      // Astro's default github-dark theme draws comments in #6a737d on
      // #24292e (3.04:1), below WCAG AA for body text (#1133). The
      // high-contrast variant keeps the GitHub palette while its comment
      // colour (#bdc4cc on #0a0c10) reaches 11.12:1.
      theme: 'github-dark-high-contrast',
    },
  },
});
