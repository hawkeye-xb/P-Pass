#!/usr/bin/env node
/**
 * Build guard (#691, #2099): fail when the generated sitemap, llms.txt,
 * published content routes, or page metadata disagree with the build.
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative, sep } from 'node:path';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const contentRoot = fileURLToPath(new URL('../src/content/', import.meta.url));
const SITE_URL = 'https://p-pass.hawkeye-xb.com';

/** Every HTML page built, as a site path ('/blog/', '/zh/faq/', '/'). */
function builtPaths() {
  const walk = (dir) =>
    readdirSync(dir).flatMap((entry) => {
      const full = join(dir, entry);
      return statSync(full).isDirectory() ? walk(full) : [full];
    });

  return new Set(
    walk(dist)
      // index.html only: assets, rss.xml, robots.txt, llms.txt and the Google
      // verification file are not indexable HTML pages.
      .filter((file) => file.endsWith(`${sep}index.html`) || file.endsWith('index.html'))
      .filter((file) => relative(dist, file) !== join('404', 'index.html'))
      .map((file) => {
        const rel = relative(dist, file).split(sep).join('/');
        return `/${rel.replace(/index\.html$/, '')}`;
      }),
  );
}

/** Every <loc> listed by the sitemap index and its slices, as site paths. */
function sitemapPaths() {
  const indexPath = join(dist, 'sitemap-index.xml');
  const index = readFileSync(indexPath, 'utf8');
  const slices = [...index.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) =>
    m[1].replace(/^https?:\/\/[^/]+/, ''),
  );

  const paths = new Set();
  for (const slice of slices) {
    const file = join(dist, slice.split('/').filter(Boolean).pop());
    for (const [, loc] of readFileSync(file, 'utf8').matchAll(/<loc>([^<]+)<\/loc>/g)) {
      paths.add(loc.replace(/^https?:\/\/[^/]+/, ''));
    }
  }
  return paths;
}

/** Read published markdown entries from a content collection directory. */
function publishedEntries(collection) {
  const dir = join(contentRoot, collection);
  const entries = [];
  for (const file of readdirSync(dir)) {
    if (!file.endsWith('.md')) continue;
    const raw = readFileSync(join(dir, file), 'utf8');
    const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
    if (!match) continue;
    const fm = match[1];
    if (/^draft:\s*true\b/m.test(fm)) continue;
    const langMatch = fm.match(/^lang:\s*['"]?(en|zh)['"]?/m);
    const lang = langMatch ? langMatch[1] : 'zh';
    const slug = file.replace(/\.md$/, '').replace(/-en$/, '');
    const path = lang === 'en' ? `/${collection}/${slug}/` : `/zh/${collection}/${slug}/`;
    entries.push({ file, lang, slug, path });
  }
  return entries;
}

const built = builtPaths();
const listed = sitemapPaths();

const missing = [...built].filter((p) => !listed.has(p)).sort();
const extra = [...listed].filter((p) => !built.has(p)).sort();

if (missing.length || extra.length) {
  console.error('sitemap does not match the built pages:');
  for (const p of missing) console.error(`  missing from sitemap: ${p}`);
  for (const p of extra) console.error(`  listed but not built: ${p}`);
  process.exit(1);
}

// Verify rss.xml and all published blog & guide pages exist in dist.
const rssPath = join(dist, 'rss.xml');
if (!existsSync(rssPath) || readFileSync(rssPath, 'utf8').trim().length === 0) {
  console.error('dist/rss.xml is missing or empty');
  process.exit(1);
}

const blogEntries = publishedEntries('blog');
const guideEntries = publishedEntries('guides');
for (const entry of [...blogEntries, ...guideEntries]) {
  if (!built.has(entry.path)) {
    console.error(`published content page missing from build: ${entry.path} (${entry.file})`);
    process.exit(1);
  }
}

// Verify guide detail pages emit BreadcrumbList, Article JSON-LD, and hreflang mirrors.
const guideSlugsByLang = {
  en: new Set(guideEntries.filter((g) => g.lang === 'en').map((g) => g.slug)),
  zh: new Set(guideEntries.filter((g) => g.lang === 'zh').map((g) => g.slug)),
};
for (const guide of guideEntries) {
  const htmlPath = join(dist, guide.path.replace(/^\//, ''), 'index.html');
  const html = readFileSync(htmlPath, 'utf8');
  if (!html.includes('"@type":"BreadcrumbList"') || !html.includes('"@type":"Article"')) {
    console.error(`guide page missing BreadcrumbList or Article JSON-LD: ${guide.path}`);
    process.exit(1);
  }
  const hasMirror =
    guide.lang === 'en' ? guideSlugsByLang.zh.has(guide.slug) : guideSlugsByLang.en.has(guide.slug);
  if (hasMirror && (!html.includes('hreflang="en"') || !html.includes('hreflang="zh-CN"'))) {
    console.error(`guide page missing bilingual hreflang alternate links: ${guide.path}`);
    process.exit(1);
  }
}

// Verify every built page has a non-empty meta description.
for (const pagePath of built) {
  const htmlPath = join(dist, pagePath.replace(/^\//, ''), 'index.html');
  const html = readFileSync(htmlPath, 'utf8');
  const descMatch = html.match(/<meta name="description" content="([^"]*)"/i);
  if (!descMatch || descMatch[1].trim().length < 30) {
    console.error(`page has missing or overly short meta description: ${pagePath}`);
    process.exit(1);
  }
}

// Verify generated llms.txt exists, contains required entries & published guide URLs, and has no forbidden terms.
const llmsPath = join(dist, 'llms.txt');
if (!existsSync(llmsPath)) {
  console.error('dist/llms.txt is missing');
  process.exit(1);
}
const llms = readFileSync(llmsPath, 'utf8');
const requiredTokens = [
  SITE_URL,
  `${SITE_URL}/guides/`,
  `${SITE_URL}/zh/guides/`,
  'Apple silicon',
  'Windows',
  'Android',
  'iPhone',
];
for (const token of requiredTokens) {
  if (!llms.includes(token)) {
    console.error(`dist/llms.txt is missing required content: ${token}`);
    process.exit(1);
  }
}
for (const guide of guideEntries) {
  const url = `${SITE_URL}${guide.path}`;
  if (!llms.includes(url)) {
    console.error(`dist/llms.txt is missing published guide URL: ${url}`);
    process.exit(1);
  }
}
if (/\bp2p\b/i.test(llms)) {
  console.error('dist/llms.txt contains disallowed wording');
  process.exit(1);
}

console.log(
  `sitemap matches the build: ${built.size} pages (${blogEntries.length} blog, ${guideEntries.length} guides, llms.txt ok)`,
);
