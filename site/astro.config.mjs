// @ts-check
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

const here = dirname(fileURLToPath(import.meta.url));
const blogDir = join(here, 'src', 'content', 'blog');
const lastmodByPath = new Map([
  ['/privacy/', '2026-10-26'],
  ['/zh/privacy/', '2026-10-26'],
  ['/terms/', '2026-09-29'],
  ['/zh/terms/', '2026-09-29'],
]);

for (const file of readdirSync(blogDir)) {
  if (!file.endsWith('.md')) continue;
  const raw = readFileSync(join(blogDir, file), 'utf8');
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) continue;
  const fm = match[1];
  const dateMatch = fm.match(/^date:\s*['"]?(\d{4}-\d{2}-\d{2})/m);
  if (!dateMatch) continue;
  const langMatch = fm.match(/^lang:\s*['"]?(en|zh)['"]?/m);
  const lang = langMatch ? langMatch[1] : 'zh';
  const slug = file.replace(/\.md$/, '').replace(/-en$/, '');
  const path = lang === 'en' ? `/blog/${slug}/` : `/zh/blog/${slug}/`;
  lastmodByPath.set(path, dateMatch[1]);
}

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
      serialize(item) {
        const path = new URL(item.url).pathname;
        const lastmod = lastmodByPath.get(path);
        if (lastmod) {
          item.lastmod = lastmod;
        }
        return item;
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
