#!/usr/bin/env node
/**
 * Build guard (#691): fail when the generated sitemap and the pages that were
 * actually built disagree.
 *
 * Why this exists: the sitemap used to be a hand-written file under
 * `public/`, so it drifted silently — ten live pages (the FAQ pages and eight
 * English blog posts) were reachable but never listed. The sitemap is now
 * derived from the route table at build time, and this check makes a
 * regression loud instead of invisible.
 *
 * Run after `astro build`: compares every `dist/**\/index.html` route against
 * the `<loc>` entries of every sitemap file listed by `dist/sitemap-index.xml`.
 * Exits 1 on any difference, with the missing and extra paths printed.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative, sep } from 'node:path';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

/** Every HTML page built, as a site path ('/blog/', '/zh/faq/', '/'). */
function builtPaths() {
  const walk = (dir) =>
    readdirSync(dir).flatMap((entry) => {
      const full = join(dir, entry);
      return statSync(full).isDirectory() ? walk(full) : [full];
    });

  return new Set(
    walk(dist)
      // index.html only: assets, rss.xml, robots.txt and the Google
      // verification file are not indexable pages.
      .filter((file) => file.endsWith(`${sep}index.html`) || file.endsWith('index.html'))
      .filter((file) => relative(dist, file) !== join('404', 'index.html'))
      // 404 lives at dist/404.html, which the filter above already skips;
      // keep the explicit check in case it ever moves back under a folder.
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

console.log(`sitemap matches the build: ${built.size} pages`);
