#!/usr/bin/env node
/**
 * Sync icon assets from docs/design/2026-08-11-icon-v1/ into site/public/icons/.
 * Source of truth stays in docs/design/; public/ only holds build-time copies.
 * Idempotent: skips files whose content already matches.
 *
 *   node scripts/sync-icons.mjs           # sync
 *   node scripts/sync-icons.mjs --check   # assert all present & identical (exit 1 if stale)
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, '..', '..', 'docs', 'design', '2026-08-11-icon-v1');
const outDir = join(here, '..', 'public', 'icons');

// Files the site uses. Keep this list explicit — no globbing.
const FILES = ['icon-beast.svg', 'icon-beast-night.svg', 'icon-carbon.svg', 'icon-carbon-night.svg'];

const check = process.argv.includes('--check');
let changed = false;

for (const f of FILES) {
  const src = join(srcDir, f);
  const dst = join(outDir, f);
  const data = readFileSync(src, 'utf8');
  const same = existsSync(dst) && readFileSync(dst, 'utf8') === data;
  if (!same) {
    if (check) {
      console.error(`icon STALE: ${f} (source changed or missing). Run \`npm run icons\` and commit the result.`);
      process.exit(1);
    }
    mkdirSync(outDir, { recursive: true });
    writeFileSync(dst, data);
    console.log(`synced ${f}`);
    changed = true;
  }
}

if (check) {
  console.log('icons match docs/design source ✓');
} else if (!changed) {
  console.log('icons already in sync ✓');
}
