#!/usr/bin/env bash
# UPD-16（#695）：**依赖缓存的 key** —— 只跟「依赖集合」走，不跟「我们自己的版本号」走。
#
# 为什么：版本 bump 会改 `Cargo.lock` 里我们自己 package 的 version 行（cargo update -w
# 同步 workspace 成员）。缓存 key 若直接 hash 整个 lock ⇒ **每次发版必然未命中** ⇒
# 必然冷编译 Tauri 桌面壳（实测 276s 暖 → 90 分钟+ 冷）。
#
# 做法：把本项目 package 段里的 `version = "x.y.z"` 归一化成 `version = "VERSION"` 再 hash。
# 依赖版本变化照常影响结果；我们自己的版本号变化不影响。
#
# 用法：tools/dep-cache-key.sh <Cargo.lock> [more.lock ...]
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <Cargo.lock> [...]" >&2; exit 1; }
for f in "$@"; do
  [ -f "$f" ] || { echo "error: $f 不存在" >&2; exit 1; }
done

for f in "$@"; do
  awk '
    # 进入「本项目自己的 package」段：这些是我们发布的 crate，不是外部依赖
    /^name = "(p-pass|p-pass-[a-z-]+|ppf-[a-z-]+|daemon|testclient|transport|platform|diag|proto)"/ { own = 1; print; next }
    own && /^version = / { print "version = \"VERSION\""; next }   # 归一化：版本号不是依赖
    own && /^\[\[package\]\]/ { own = 0 }                        # 下一段开始 ⇒ 退出
    { print }
  ' "$f"
done | shasum -a 256 | cut -c1-40
