#!/usr/bin/env python3
"""Flag Markdown tables broken by a stray blank line.

GFM table syntax ends a table at the first blank line. A row that was meant
to continue the same table but got separated by one or more blank lines does
NOT start a new table (no header + separator row directly above it), so it
silently renders as a raw pipe-delimited text line instead of a table row.

2026-09 finding: docs/QUEUE.md accumulated several of these (rows split off
from their table by blank lines left over from editing), and nothing caught
it — `queue-check` only verifies card links, not table well-formedness. This
script closes that gap.

Detection rule: a pipe-row (line trimmed starts and ends with '|') that is
preceded — skipping only blank lines — by another pipe-row, but is NOT itself
immediately followed by a valid separator row (`|---|---|`), is flagged as an
orphaned continuation of the table above. A pipe-row that *is* followed by a
proper separator row is a legitimate new table and is not flagged.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PIPE_ROW = re.compile(r"^\|.*\|$")
SEPARATOR_ROW = re.compile(r"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?$")


def is_pipe_row(line: str) -> bool:
    s = line.strip()
    return bool(s) and bool(PIPE_ROW.match(s))


def is_separator_row(line: str) -> bool:
    return bool(SEPARATOR_ROW.match(line.strip()))


def check_file(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    problems: list[tuple[int, str]] = []

    last_nonblank_idx: int | None = None
    blank_run = 0

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "":
            blank_run += 1
            continue

        if is_pipe_row(line) and blank_run > 0 and last_nonblank_idx is not None:
            prev_line = lines[last_nonblank_idx]
            if is_pipe_row(prev_line):
                next_line = lines[i + 1] if i + 1 < len(lines) else ""
                if not is_separator_row(next_line):
                    problems.append(
                        (
                            i + 1,
                            f"table row separated from the table above by "
                            f"{blank_run} blank line(s) and not starting a "
                            f"new table (line {last_nonblank_idx + 1} was the "
                            f"last row of that table) — merge them (delete "
                            f"the blank line) or give this row its own "
                            f"header + separator row.",
                        )
                    )

        blank_run = 0
        last_nonblank_idx = i

    return problems


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    targets: list[Path] = []
    for pattern in ("docs/**/*.md", "cards/**/*.md"):
        targets.extend(sorted(root.glob(pattern)))

    fail = False
    for path in targets:
        problems = check_file(path)
        if problems:
            fail = True
            rel = path.relative_to(root)
            for lineno, msg in problems:
                print(f"   FAIL broken-table: {rel}:{lineno}: {msg}")

    if fail:
        print("")
        print("Markdown 表格被空行切断——见上方，逐处修好再提交。")
        return 1

    print(f"ok: {len(targets)} 个 Markdown 文件里没有被空行切断的表格")
    return 0


if __name__ == "__main__":
    sys.exit(main())
