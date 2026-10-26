#!/usr/bin/env bash
# #1151：audit-deps.yml 的扫描步骤。用法：.github/osv/scan.sh <osv-scanner 二进制>
#
# 两处口径（都是为了「报的都是该处理的」）：
#   1. Gradle 只看发布包（releaseRuntimeClasspath）。lockfile 里还有 lint / AGP / 测试等
#      构建期类路径，那些依赖不进用户手里的 APK，混进来只会淹没真正该处理的公告。
#   2. Cargo 里凡是带 RUSTSEC 编号的公告不在这里重复报——它们归 cargo-deny（audit-advisories.yml
#      与 ci-rust 的 deny.toml 管豁免）。本步只补 cargo-deny 看不到的：仅有 GHSA 编号的 Rust 公告。
set -euo pipefail
OSV="${1:?用法：scan.sh <osv-scanner>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

LOCK=apps/android/app/gradle.lockfile
[ -s "$LOCK" ] || { echo "::error::$LOCK 不存在或为空——Gradle 部分会变成什么都没扫" >&2; exit 1; }
mkdir -p "$TMP/gradle-release"
# lockfile 行形如 group:artifact:version=conf1,conf2,…；注释行（#）原样不要。
grep -v '^#' "$LOCK" | grep -E '=([^=]*,)?releaseRuntimeClasspath(,|$)' > "$TMP/gradle-release/body" || true
[ -s "$TMP/gradle-release/body" ] || { echo "::error::lockfile 里没有 releaseRuntimeClasspath 的依赖——过滤口径失效" >&2; exit 1; }
{ echo "# filtered: releaseRuntimeClasspath"; cat "$TMP/gradle-release/body"; } > "$TMP/gradle-release/gradle.lockfile"
echo "Gradle 发布包依赖：$(wc -l < "$TMP/gradle-release/body") 条"

rc=0
"$OSV" scan source --format json --config .github/osv/osv-scanner.toml \
  --lockfile Cargo.lock \
  --lockfile apps/desktop/src-tauri/Cargo.lock \
  --lockfile "$TMP/gradle-release/gradle.lockfile" > "$TMP/osv.json" || rc=$?
# osv-scanner：0 = 没有漏洞，1 = 有漏洞；其余（127 出错 / 128 没找到任何包）都是扫描本身坏了。
[ "$rc" -le 1 ] || { echo "::error::osv-scanner 退出码 ${rc}（不是「有 / 没有漏洞」）" >&2; exit 1; }

jq -r '
  .results[]? | .packages[]? | .package as $k | .vulnerabilities[]?
  | select($k.ecosystem != "crates.io"
           or (([.id] + (.aliases // [])) | map(startswith("RUSTSEC-")) | any | not))
  | [$k.ecosystem, $k.name, $k.version, .id] | @tsv' "$TMP/osv.json" | sort -u > "$TMP/findings.tsv"

if [ -s "$TMP/findings.tsv" ]; then
  echo "::error::发现需要处理的依赖公告（生态 / 包 / 版本 / 公告）：" >&2
  column -t -s $'\t' "$TMP/findings.tsv" >&2
  exit 1
fi
echo "ok：没有需要处理的公告（Cargo 的 RUSTSEC 由 cargo-deny 管）"
