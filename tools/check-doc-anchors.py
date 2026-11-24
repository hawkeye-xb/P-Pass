#!/usr/bin/env python3
"""Check document anchors and links across tiers with zero external dependencies.

Tiers:
  --tier 1 (Active AI & development guidelines):
      Scans AGENTS.md, CLAUDE.md, docs/runbook/**/*.md, docs/RELEASING.md,
      docs/release-notes-rules.md, docs/AGENT_PROTOCOL.md, docs/desktop/business-rules.zh-CN.md.
      Checks:
        1. Markdown relative links target real existing files.
        2. Backtick repository file/directory paths (excluding placeholders like <...>, *, ...,
           branch patterns release/vX.Y, external ../private, etc.) exist.
        3. Backtick `just <recipe>` calls exist in the root justfile.

  --tier 2 (Historical decisions, product, lessons, security):
      Scans docs/decisions/**/*.md, docs/product/**/*.md, docs/lessons/**/*.md,
      docs/security/**/*.md.
      Checks:
        1. Markdown relative links target real existing files.
        (Does NOT enforce code path freshness on historical docs).

  --tier 3 (Site blog & documentation):
      Scans site/**/*.md.
      Checks:
        1. Markdown relative links target real existing files.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# Regular expressions
MARKDOWN_LINK_RE = re.compile(r'\[([^\]]*)\]\(([^)]+)\)')
CODE_SPAN_RE = re.compile(r'`([^`\n]+)`')

TOP_REPO_DIRS = (
    'tools/',
    'docs/',
    'crates/',
    'apps/',
    'assets/',
    '.github/',
    'release/',
    'site/',
)

KNOWN_ROOT_FILES = {
    'justfile',
    'Cargo.toml',
    'rust-toolchain.toml',
    'package.json',
    'pnpm-workspace.yaml',
    'AGENTS.md',
    'CLAUDE.md',
    '.gitignore',
}

KNOWN_EXTENSIONS = (
    '.md',
    '.rs',
    '.py',
    '.sh',
    '.yml',
    '.yaml',
    '.toml',
    '.json',
    '.kt',
    '.swift',
    '.js',
    '.mjs',
    '.ps1',
    '.lock',
    '.sql',
)


def get_just_recipes(repo_root: Path) -> set[str]:
    justfile = repo_root / 'justfile'
    if not justfile.exists():
        return set()
    try:
        res = subprocess.run(
            ['just', '--summary'],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            check=True,
        )
        return set(res.stdout.strip().split())
    except Exception:
        # Fallback to parsing recipe names from justfile
        recipes = set()
        for line in justfile.read_text(encoding='utf-8', errors='ignore').splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^([a-zA-Z0-9_-]+)(?:\s+[^:=]*)*:', line)
            if m:
                recipes.add(m.group(1))
        return recipes


def check_markdown_links(file_path: Path, repo_root: Path) -> list[str]:
    errors = []
    try:
        text = file_path.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        return [f"{file_path}: cannot read file: {e}"]

    lines = text.splitlines()
    in_code_block = False

    for line_no, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        for m in MARKDOWN_LINK_RE.finditer(line):
            target = m.group(2).strip()
            # Ignore anchors, external URLs, mailto
            if (
                target.startswith('#')
                or target.startswith('http://')
                or target.startswith('https://')
                or target.startswith('mailto:')
            ):
                continue

            target_path = target.split('#')[0].split('?')[0].strip()
            if not target_path:
                continue

            # Check if this file is under site/
            is_site_doc = False
            try:
                rel = file_path.resolve().relative_to(repo_root)
                if rel.parts and rel.parts[0] == 'site':
                    is_site_doc = True
            except Exception:
                pass

            if is_site_doc:
                # If target is web absolute (e.g. /blog/..., /icons/...), check against site/public or ignore web route
                if target_path.startswith('/'):
                    # Check if it exists in site/public/
                    public_target = repo_root / 'site' / 'public' / target_path.lstrip('/')
                    if public_target.exists():
                        continue
                    # Common site routes like /blog/, /zh/blog/ are Astro dynamic routes
                    if target_path.startswith('/blog') or target_path.startswith('/zh/blog'):
                        continue
                    # Other web-root references
                    continue

            resolved = (file_path.parent / target_path).resolve()
            # Also check if it's meant relative to repo root if starts with a repo root dir
            resolved_root = (repo_root / target_path.lstrip('/')).resolve()

            if not resolved.exists() and not resolved_root.exists():
                rel_f = file_path.relative_to(repo_root) if file_path.is_relative_to(repo_root) else file_path
                errors.append(f"{rel_f}:{line_no}: broken link -> {target}")

    return errors


def check_tier1_anchors(
    file_path: Path, repo_root: Path, just_recipes: set[str]
) -> list[str]:
    errors = []
    try:
        text = file_path.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        return [f"{file_path}: cannot read file: {e}"]

    lines = text.splitlines()
    in_code_block = False

    for line_no, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        for m in CODE_SPAN_RE.finditer(line):
            code = m.group(1).strip()

            # 1. Check `just <recipe>` calls
            if code.startswith('just '):
                parts = code.split()
                if len(parts) >= 2:
                    subcmd = parts[1]
                    if (
                        not subcmd.startswith('-')
                        and '<' not in subcmd
                        and '[' not in subcmd
                        and '*' not in subcmd
                    ):
                        if just_recipes and subcmd not in just_recipes:
                            rel_f = file_path.relative_to(repo_root) if file_path.is_relative_to(repo_root) else file_path
                            errors.append(
                                f"{rel_f}:{line_no}: unknown just recipe `{subcmd}` (in `{code}`)"
                            )

            # 2. Check repo file / directory paths
            for token in code.split():
                t = token.strip('"`\'')
                # Trim surrounding punctuation (English and Chinese)
                t = re.sub(r'[:;,。，；（）\(\)\[\]\{\}]+$', '', t)
                t = re.sub(r'^[:;,。，；（）\(\)\[\]\{\}]+', '', t)

                # Skip placeholders, patterns, and non-repo indicators
                if any(x in t for x in ['<', '>', '*', '...', '…', '$', '{', '}', '~', '://', 'git@', '\\']):
                    continue
                if t.startswith('-'):
                    continue
                # Exclude git refs / branches / special paths
                if (
                    t.startswith('origin/')
                    or t.startswith('refs/')
                    or t.startswith('release/v')
                    or t.startswith('release/update-keys/stable.retiring.pub')
                    or t.startswith('releases/latest/')
                    or t.startswith('test-channel/')
                    or t in ['HEAD', 'FETCH_HEAD']
                    or t.startswith('../private')
                    or t.startswith('../.env.ppass-dev')
                    or t.startswith('files/')
                ):
                    continue

                is_repo_path = False
                if any(t.startswith(d) for d in TOP_REPO_DIRS):
                    is_repo_path = True
                elif t in KNOWN_ROOT_FILES:
                    is_repo_path = True
                elif t.startswith('./') or t.startswith('../'):
                    is_repo_path = True
                elif '/' in t and any(t.endswith(ext) for ext in KNOWN_EXTENSIONS):
                    is_repo_path = True

                if is_repo_path:
                    # Strip line numbers like :314 or :28-35
                    clean_path = re.sub(r':\d+(?:-\d+)?$', '', t)
                    # This machine-local file is intentionally absent from clean checkouts.
                    if Path(clean_path).as_posix() == '.claude/settings.local.json':
                        continue
                    p_root = repo_root / clean_path
                    p_rel = file_path.parent / clean_path

                    if not p_root.exists() and not p_rel.exists():
                        rel_f = file_path.relative_to(repo_root) if file_path.is_relative_to(repo_root) else file_path
                        errors.append(
                            f"{rel_f}:{line_no}: missing repo path `{t}` (in `{code}`)"
                        )

    return errors


def run_checks(tier: int, repo_root: Path) -> int:
    all_errors = []

    if tier == 1:
        t1_patterns = [
            'AGENTS.md',
            'CLAUDE.md',
            'docs/runbook/**/*.md',
            'docs/RELEASING.md',
            'docs/release-notes-rules.md',
            'docs/AGENT_PROTOCOL.md',
            'docs/desktop/business-rules.zh-CN.md',
        ]
        files = sorted(
            {p for pat in t1_patterns for p in repo_root.glob(pat) if p.is_file()}
        )
        just_recipes = get_just_recipes(repo_root)
        print(f"[Tier 1] Checking {len(files)} active guideline documents...")

        for f in files:
            all_errors.extend(check_markdown_links(f, repo_root))
            all_errors.extend(check_tier1_anchors(f, repo_root, just_recipes))

    elif tier == 2:
        t2_patterns = [
            'docs/decisions/**/*.md',
            'docs/product/**/*.md',
            'docs/lessons/**/*.md',
            'docs/security/**/*.md',
        ]
        files = sorted(
            {p for pat in t2_patterns for p in repo_root.glob(pat) if p.is_file()}
        )
        print(f"[Tier 2] Checking {len(files)} historical decision/record documents...")

        for f in files:
            all_errors.extend(check_markdown_links(f, repo_root))

    elif tier == 3:
        files = sorted(
            {p for p in repo_root.glob('site/**/*.md') if p.is_file()}
        )
        print(f"[Tier 3] Checking {len(files)} site/blog documents...")

        for f in files:
            all_errors.extend(check_markdown_links(f, repo_root))

    else:
        print(f"Unknown tier: {tier}", file=sys.stderr)
        return 1

    if all_errors:
        print(f"FAILED: Found {len(all_errors)} anchor/link error(s):", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"OK: Tier {tier} documents all valid")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--tier',
        type=int,
        choices=[1, 2, 3],
        required=True,
        help='Documentation tier to validate (1=active guidelines, 2=historical, 3=site)',
    )
    parser.add_argument(
        '--root',
        type=Path,
        default=None,
        help='Repository root directory (defaults to current working directory)',
    )
    args = parser.parse_args()

    repo_root = (args.root or Path('.')).resolve()
    return run_checks(args.tier, repo_root)


if __name__ == '__main__':
    sys.exit(main())
