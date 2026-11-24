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
      Scans site/**/*.md, excluding dependencies and generated output.
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
    res = subprocess.run(
        ['just', '--justfile', str(repo_root / 'justfile'), '--summary'],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )
    recipes = set(res.stdout.split())
    if not recipes:
        raise ValueError('just --summary returned no recipes')
    return recipes


FENCE_RE = re.compile(r'^[ ]{0,3}(`{3,}|~{3,})(.*)$')
REFERENCE_TARGET_RE = re.compile(r'^[ ]{0,3}\[[^]\n]+\]:[ \t]*(<[^>]+>|\S+)')


def prose_lines(text: str):
    fence = None
    for line_no, line in enumerate(text.splitlines(), 1):
        match = FENCE_RE.match(line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence) and not match[2].strip():
                fence = None
            continue
        if match and (match[1][0] == '~' or '`' not in match[2]):
            fence = match[1]
            continue
        yield line_no, line


def check_markdown_links(file_path: Path, repo_root: Path) -> list[str]:
    try:
        text = file_path.read_text(encoding='utf-8', errors='replace')
    except OSError as exc:
        return [f"{file_path}: cannot read file: {exc}"]

    errors = []
    rel = file_path.relative_to(repo_root)
    is_site_doc = rel.parts[0] == 'site'
    for line_no, line in prose_lines(text):
        ref = REFERENCE_TARGET_RE.match(line)
        targets = [ref[1]] if ref else [m[2].strip() for m in MARKDOWN_LINK_RE.finditer(line)]
        for target in targets:
            if target.startswith('<') and '>' in target:
                target = target[1:target.index('>')]
            elif target:
                target = target.split(maxsplit=1)[0]
            if target.startswith(('#', '//', 'http://', 'https://', 'mailto:')):
                continue
            target_path = target.split('#')[0].split('?')[0]
            if not target_path:
                continue

            if target_path.startswith('/'):
                if is_site_doc:
                    # Astro owns site routes; icons and videos are served from public/.
                    if not target_path.startswith(('/icons/', '/video/')):
                        continue
                    resolved = repo_root / 'site' / 'public' / target_path.lstrip('/')
                else:
                    resolved = repo_root / target_path.lstrip('/')
            else:
                resolved = file_path.parent / target_path
            if not resolved.exists():
                errors.append(f"{rel}:{line_no}: broken link -> {target}")

    return errors


def check_tier1_anchors(
    file_path: Path, repo_root: Path, just_recipes: set[str]
) -> list[str]:
    errors = []
    try:
        text = file_path.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        return [f"{file_path}: cannot read file: {e}"]

    for line_no, line in prose_lines(text):
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
                        if subcmd not in just_recipes:
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
        try:
            just_recipes = get_just_recipes(repo_root)
        except (OSError, subprocess.CalledProcessError, ValueError) as exc:
            detail = getattr(exc, 'stderr', None) or str(exc)
            print(f"cannot validate just recipes: {detail.strip()}", file=sys.stderr)
            return 1
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
        generated_dirs = {'node_modules', 'dist', '.astro'}
        files = []
        for directory, subdirs, names in os.walk(repo_root / 'site'):
            subdirs[:] = [name for name in subdirs if name not in generated_dirs]
            files.extend(Path(directory) / name for name in names if name.endswith('.md'))
        files.sort()
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
