#!/usr/bin/env python3
"""shell 变量紧挨非 ASCII 字符时必须写成 ${name}。

为什么：macOS 自带的 /bin/bash 3.2 在 UTF-8 locale 下会把多字节字符的首字节当成
变量名的一部分——`echo "「$name」"` 在 `set -u` 下直接报 `name�: unbound variable`。
Linux 的 bash 5 不受影响，所以只在 macOS 上（发布链的 macOS job、本机脚本）出事。
现场：v0.9.12-test.5 的 macOS 构建里 codesign 卡住，with-timeout.sh 打印超时提示的那一行
先崩了，重试没有发生（#772 的重试机制形同虚设）。

规则只有一条：`$` 后面紧跟变量名、再紧跟非 ASCII 字符 = 违规。改成 `${name}` 即可。
扫描范围：git 跟踪的 *.sh / *.bash、.github/workflows/*.yml、justfile。整行注释不查。

用法：python3 tools/check-shell-vars.py [--self-test]
"""

import re
import subprocess
import sys

PATTERN = re.compile(r"(?<![\\$])\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])")


def violations(text):
    out = []
    for n, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in PATTERN.finditer(line):
            out.append((n, m.group(1), line.strip()))
    return out


def scanned_files():
    files = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout.split()
    return [
        f
        for f in files
        if f.endswith((".sh", ".bash"))
        or (f.startswith(".github/workflows/") and f.endswith((".yml", ".yaml")))
        or f == "justfile"
    ]


def self_test():
    bad = ['echo "「$name」"', 'say "lane=$LANE）"', 'x="$a，$b"']
    good = ['echo "「${name}」"', 'echo "$name ok"', "echo '\\$HOME（字面量）'", "# 注释 $x」", 'p="$$（pid）"']
    ok = True
    for s in bad:
        if not violations(s):
            print(f"self-test: 漏抓 {s!r}")
            ok = False
    for s in good:
        if violations(s):
            print(f"self-test: 误报 {s!r}")
            ok = False
    print("ok: self-test" if ok else "self-test FAILED")
    return ok


def main():
    if "--self-test" in sys.argv:
        sys.exit(0 if self_test() else 1)
    found = 0
    for f in scanned_files():
        try:
            text = open(f, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for n, name, line in violations(text):
            found += 1
            print(f"   FAIL {f}:{n}: ${name} 紧挨非 ASCII 字符，改成 ${{{name}}} | {line[:120]}")
    if found:
        print(f"\n{found} 处 shell 变量紧挨非 ASCII 字符——macOS /bin/bash 3.2 会把它读成别的变量名，逐处改成 ${{name}}。")
        sys.exit(1)
    print("ok: shell 变量与非 ASCII 字符之间都有花括号")


if __name__ == "__main__":
    main()
