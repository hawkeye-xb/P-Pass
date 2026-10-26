#!/usr/bin/env python3
"""SEC-09 (#371): 供应链门禁 minimumReleaseAge 的豁免名单必须是「显式批准」的东西。

背景：pnpm 11 内置 minimumReleaseAge（不许装发布不足 24 小时的包），但它会自己往
pnpm-workspace.yaml 写 minimumReleaseAgeExclude 来绕过——一句普通的 `pnpm install`、
或照着报错提示跑 `pnpm clean --lockfile`，都可能触发。写进去的几行混在依赖 diff 里，
review 极易放过，进了 main 就永久豁免。

本脚本把「新增豁免」变成必红：
  1. 仓库里任何 pnpm 配置（pnpm-workspace.yaml / .npmrc / package.json）出现的
     minimumReleaseAgeExclude 条目，必须在 tools/release-age-exclude-allowlist.txt
     登记（`包@版本 | 理由`）。没登记 = 红。
  2. 登记了但配置里已不存在的条目同样红（名单只许缩，过期豁免不留）。
  3. 每个 pnpm-workspace.yaml 必须声明 `minimumReleaseAgeStrict: true`：它让 pnpm
     遇到不满足门禁的包时报错退出，而不是自己写豁免。

正确做法不是登记豁免，而是把依赖 pin 到发布已久的版本（cutoff 是跑 CI 那一刻往前
推 24 小时，留足余量）。必须豁免时：在白名单里加一行并说明理由，这一行就是 reviewer
要明确放行的 diff。

用法：python3 tools/check-release-age-exclude.py [--root DIR]
只依赖标准库与 git（git ls-files 取受控文件）。
"""
import argparse
import os
import re
import subprocess
import sys

KEY_RE = re.compile(r"minimum[-_]?release[-_]?age[-_]?exclude", re.I)
STRICT_RE = re.compile(r"^\s*minimumReleaseAgeStrict\s*:\s*(\S+)")
CONFIG_NAMES = {"pnpm-workspace.yaml", ".npmrc", "package.json"}
ALLOWLIST = "tools/release-age-exclude-allowlist.txt"


def tracked_files(root):
    out = subprocess.run(
        ["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True
    ).stdout.decode()
    return [p for p in out.split("\0") if p]


def strip_comment(line):
    # 引号内不会出现 ' #'（包名/版本号不含空格），按「空白 + #」剥注释足够。
    m = re.search(r"(^|\s)#", line)
    return line[: m.start()] if m else line


def unquote(s):
    return s.strip().strip(",").strip().strip("'\"").strip()


def yaml_entries(lines, idx, key_indent, rest):
    """返回 (entries, errors)。支持块列表与行内 [a, b]；其他写法一律当错误（拒绝猜）。"""
    rest = rest.strip()
    if rest.startswith("["):
        body = rest
        j = idx
        while "]" not in body:
            j += 1
            if j >= len(lines):
                return [], ["行内列表没有结束的 ]"]
            body += " " + strip_comment(lines[j]).strip()
        inner = body[body.index("[") + 1 : body.index("]")]
        return [unquote(x) for x in inner.split(",") if x.strip()], []
    if rest in ("", "|", ">"):
        entries = []
        for line in lines[idx + 1 :]:
            line = strip_comment(line.rstrip("\n"))
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip())
            body = line.strip()
            if indent <= key_indent and not body.startswith("- "):
                break
            if body.startswith("- "):
                entries.append(unquote(body[2:]))
            else:
                return entries, [f"无法解析的列表行: {body!r}"]
        return entries, []
    return [], [f"无法解析的写法: {rest!r}（只认块列表或行内 [..]）"]


def scan(root):
    problems = []
    found = {}  # 条目 -> 出处
    for rel in tracked_files(root):
        name = os.path.basename(rel)
        if name not in CONFIG_NAMES:
            continue
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError) as e:
            problems.append(f"{rel}: 读不了 ({e})")
            continue
        if name == "pnpm-workspace.yaml":
            vals = [
                m.group(1).strip("'\"")
                for m in (STRICT_RE.match(strip_comment(l)) for l in lines)
                if m
            ]
            if vals != ["true"]:
                problems.append(
                    f"{rel}: 必须有且只有一行 `minimumReleaseAgeStrict: true`（现为 {vals or '缺失'}）"
                    "——没有它 pnpm 会自己往 minimumReleaseAgeExclude 写豁免"
                )
        for i, raw in enumerate(lines):
            line = strip_comment(raw)
            if not KEY_RE.search(line):
                continue
            where = f"{rel}:{i + 1}"
            if name == "pnpm-workspace.yaml":
                m = re.match(r"^(\s*)[\"']?[\w-]+[\"']?\s*:(.*)$", line)
                if not m or not KEY_RE.search(line.split(":")[0]):
                    problems.append(f"{where}: 无法解析 {raw.strip()!r}")
                    continue
                entries, errs = yaml_entries(lines, i, len(m.group(1)), m.group(2))
                problems += [f"{where}: {e}" for e in errs]
                for e in entries:
                    found.setdefault(e, where)
            else:
                # .npmrc / package.json：不去解析，出现即登记一个「位置条目」。
                found.setdefault(f"<{where}>", where)
    return found, problems


def load_allowlist(root):
    path = os.path.join(root, ALLOWLIST)
    allowed = {}
    if not os.path.exists(path):
        return allowed, [f"{ALLOWLIST} 不存在（空名单也要有这个文件）"]
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            ent, _, why = (p.strip() for p in line.partition("|"))
            if not ent or not why:
                return allowed, [f"{ALLOWLIST}:{n}: 格式必须是 `包@版本 | 理由`"]
            allowed[ent] = n
    return allowed, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    root = ap.parse_args().root
    found, problems = scan(root)
    allowed, errs = load_allowlist(root)
    problems += errs
    for ent, where in sorted(found.items()):
        if ent not in allowed:
            problems.append(
                f"{where}: minimumReleaseAgeExclude 新增条目 {ent}——这是在绕过供应链门禁（#371）。"
                "正确做法：把依赖 pin 到发布已久的版本；确需豁免才在 "
                f"{ALLOWLIST} 登记并写明理由，由 reviewer 明确放行"
            )
    for ent, n in sorted(allowed.items()):
        if ent not in found:
            problems.append(f"{ALLOWLIST}:{n}: 登记的豁免 {ent} 在配置里已不存在，请删掉（名单只许缩）")
    if problems:
        print("release-age-exclude-check: FAIL", file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        return 1
    print(f"release-age-exclude-check: ok（豁免条目 {len(found)}，均已登记）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
