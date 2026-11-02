#!/usr/bin/env python3
"""门禁：占盘 1x 的结构信号（AGENTS.md 产品硬规矩「占盘 1x」）。

「隔离区、回收站、缓存、staging 只增不删都算违规」。机器判不了「删不删」，但能挡住**悄悄多出一个目录**：
扫描 crates/ 与桌面壳 Rust 源码里写盘用的目录名——
  · 所有 `.ppf/<名字>` 路径字面量（库盘上的服务私有目录）；
  · `const …_DIR/_PREFIX/_DIRNAME/_FOLDER: &str = "…"` 里含 quarantine|trash|recycle|staging|cache|spool|retired|
    superseded|stash|blob|thumb 这类关键词的目录名；
  · `.join("…")` 里含同类关键词的目录名。
每个目录必须在 tools/disk-growth-registry.txt 登记「清理触发条件」：
  dir|<名字>|<谁、在什么条件下清理它 / 或为何不随照片数增长>
写不出清理触发条件的目录，就是 AGENTS.md 说的违规，该先补清理再合入。未登记 → 红；登记了却不再出现 → 红。
范围限制：只看 Rust 侧（库盘与本机数据目录）；手机端临时目录靠真机 `du -sh` 验收（AGENTS.md「占盘 1x」）。
自测：tools/test-check-disk-growth.sh。
"""
from __future__ import annotations

import re
from pathlib import Path

from fitness_lib import compare, die, load_registry, parse_args, read_product, tracked_files

KW = r"(?:quarantine|trash|recycle|staging|cache|spool|retired|superseded|stash|blobs?|thumbs?)"
PPF = re.compile(r"\.ppf/([A-Za-z0-9_-]+)")
CONST = re.compile(r'\bconst\s+[A-Z0-9_]*(?:DIR|PREFIX|DIRNAME|FOLDER)[A-Z0-9_]*\s*:\s*&(?:\'static\s+)?str\s*=\s*"([^"]*' + KW + r'[^"]*)"')
JOIN = re.compile(r'\.join\(\s*"([A-Za-z0-9_.-]*' + KW + r'[A-Za-z0-9_.-]*)"\s*\)')


def norm(name: str) -> str:
    return name[len(".ppf/"):] if name.startswith(".ppf/") else name


def main() -> None:
    args = parse_args("占盘 1x 结构信号门禁")
    root = Path(args.root)
    reg = load_registry(Path(args.registry or root / "tools/disk-growth-registry.txt"), {"dir": 3})
    found: dict[tuple[str, str], str] = {}
    for rel in tracked_files(root):
        if not rel.endswith(".rs"):
            continue
        for n, line in read_product(root, rel):
            for rx in (PPF, CONST, JOIN):
                for m in rx.finditer(line):
                    found.setdefault(("dir", norm(m.group(1))), f"{rel}:{n}")
    errs = compare(found, reg, "落盘目录",
                   "在 tools/disk-growth-registry.txt 登记 `dir|名字|清理触发条件`；"
                   "写不出清理触发条件就先补清理（隔离区 / 回收站 / 缓存 / staging 只增不删是违规）")
    if errs:
        die(errs)
    print(f"ok: 落盘目录与 tools/disk-growth-registry.txt 一致（{len(reg)} 个，均有清理触发条件）")


if __name__ == "__main__":
    main()
