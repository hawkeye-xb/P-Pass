#!/usr/bin/env node
/**
 * Generate src/styles/tokens.css from ../../assets/design/tokens.json
 * (single source of truth). Idempotent: rerunning produces identical output.
 *
 *   node scripts/generate-tokens.mjs           # write
 *   node scripts/generate-tokens.mjs --check   # assert file matches (exit 1 if stale)
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const tokensPath = join(here, '..', '..', 'assets', 'design', 'tokens.json');
const outPath = join(here, '..', 'src', 'styles', 'tokens.css');

const tokens = JSON.parse(readFileSync(tokensPath, 'utf8'));

const lines = [];
lines.push('/*');
lines.push(' * AUTO-GENERATED from assets/design/tokens.json — DO NOT EDIT BY HAND.');
lines.push(' * Source of truth: assets/design/tokens.json (edit there, run `npm run tokens`).');
lines.push(' *');
for (const rule of tokens.rules ?? []) {
  lines.push(' * ' + rule);
}
lines.push(' */');
lines.push('');

// Color tokens: --<key>. tokens.json ships one warm light palette only;
// dark mode is implemented in global.css by inverting with existing token
// values (surface-dark as background, paper as text) — no new colors.
const colorPairs = [];
for (const [key, spec] of Object.entries(tokens.color ?? {})) {
  colorPairs.push([`--${key}`, spec.value]);
}

// Font tokens.
for (const [key, spec] of Object.entries(tokens.font ?? {})) {
  colorPairs.push([`--font-${key}`, spec.value]);
}

// Radius tokens.
for (const [key, spec] of Object.entries(tokens.radius ?? {})) {
  colorPairs.push([`--radius-${key}`, spec.value]);
}

// Size tokens (flatten desktop/mobile groups).
for (const [group, specs] of Object.entries(tokens.size ?? {})) {
  for (const [key, spec] of Object.entries(specs)) {
    colorPairs.push([`--size-${group}-${key}`, spec.value]);
  }
}

lines.push(':root {');
for (const [name, value] of colorPairs) {
  lines.push(`  ${name}: ${value};`);
}
lines.push('}');
lines.push('');

const output = lines.join('\n');
mkdirSync(dirname(outPath), { recursive: true });

const check = process.argv.includes('--check');
const existing = (() => { try { return readFileSync(outPath, 'utf8'); } catch { return null; } })();

if (check) {
  if (existing !== output) {
    console.error(`tokens.css is STALE (${outPath}). Run \`npm run tokens\` and commit the result.`);
    process.exit(1);
  }
  console.log('tokens.css matches tokens.json ✓');
} else {
  writeFileSync(outPath, output);
  console.log(`tokens.css written (${output.length} bytes) from ${tokensPath}`);
}
