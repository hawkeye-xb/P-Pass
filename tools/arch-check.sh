#!/usr/bin/env bash
# Architecture enforcement script for P-Pass
# Rules:
#   B.1 — `iroh` only in crates/transport/
#   B.2 — platform cfg only in crates/platform/, subject to the exemptions
#         documented in the B.2 block below. Covers #[cfg(...)],
#         #[cfg_attr(...)], and cfg!(...) forms, on every platform axis:
#         unix, windows, linux, macos, target_os, target_family, target_env.
#         Err on the side of false positives; the platform crate is exempt.
#   B.3 — 设备记录不得物理删除（DEV-02）：crates/ 内不允许出现
#         `DELETE FROM device` / `DELETE FROM backup_watermark`。跨行、引号、
#         schema 前缀写法同样拦（#1040）。
#   G1  — 桌面壳（apps/desktop）不判断平台、不读 HOME/USERPROFILE/LANG、
#         不拼 plist 路径。平台信息只许经 adapter 或 daemon 返回的字段（#1040）。
#   G5  — 平台实现只在 crates/platform（#1040，细则见下方 G1/G5 段）。
#   G1/G5 是「存量不增」的锁：现有越界登记在 tools/arch-allowlist.txt，
#   登记数必须与命中数精确相等，且登记相对基线分支只许降、不许升。
#   迁移卡做完后该文件清零。自测：tools/test-arch-check.sh。
#
# 环境变量（给自测与「只报告」模式用，CI 不设置）：
#   ARCH_ROOT           被检查的仓库根（默认脚本所在仓库）
#   ARCH_ALLOWLIST      白名单路径（默认 $ARCH_ROOT/tools/arch-allowlist.txt）
#   ARCH_REPORT_ONLY=1  G1/G5 只打印全部命中，不比对白名单、不判红
#   ARCH_BASE_REF       白名单「只降不升」的基线 git ref（默认 origin/main）
#   ARCH_RATCHET_SKIP=1 显式跳过基线比对（push 到 main：PR 阶段已比过）
set -euo pipefail

FAIL=0
ROOT="${ARCH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ALLOWLIST="${ARCH_ALLOWLIST:-$ROOT/tools/arch-allowlist.txt}"
REPORT_ONLY="${ARCH_REPORT_ONLY:-0}"

# ── B.1: iroh isolation ─────────────────────────────

echo "==> B.1: iroh import isolation (transport only)"

# Find Rust files outside crates/transport/ that reference 'iroh' as a crate import
# (exclude comments and string literals — just look for `use iroh` or `iroh::` or `extern crate iroh`)
VIOLATIONS_B1=$(grep -rn --include='*.rs' \
  -E '(^use iroh|iroh::|extern crate iroh)' \
  "$ROOT/crates" \
  | grep -v 'crates/transport/' \
  || true)

if [ -n "$VIOLATIONS_B1" ]; then
  echo "❌ B.1 VIOLATION: iroh imports found outside crates/transport/:"
  echo "$VIOLATIONS_B1"
  FAIL=1
else
  echo "   ✅ B.1: clean"
fi

# Also check Cargo.toml dependencies for iroh outside transport
VIOLATIONS_B1_TOML=$(grep -rn --include='Cargo.toml' \
  -E '^iroh' \
  "$ROOT/crates" \
  | grep -v 'crates/transport/' \
  || true)

if [ -n "$VIOLATIONS_B1_TOML" ]; then
  echo "❌ B.1 VIOLATION: iroh dependency in Cargo.toml outside crates/transport/:"
  echo "$VIOLATIONS_B1_TOML"
  FAIL=1
else
  echo "   ✅ B.1 (Cargo.toml): clean"
fi

# ── B.2: platform cfg isolation ─────────────────────

echo "==> B.2: platform #[cfg] / cfg_attr / cfg!() isolation (platform crate only)"

# What counts as a platform cfg (QA-09 #186 ruling): any cfg WE wrote that
# forks behavior per operating system — #[cfg(unix)], #[cfg(not(unix))],
# #[cfg(windows)], #[cfg(target_os = "...")], cfg!(...), and the same
# predicates inside #[cfg_attr(...)]. Framework-provided cross-platform APIs
# never surface here, so they are out of scope by construction.
#
# Scan scope (QA-09 #186 acceptance 4):
#   crates/** — always scanned.
#   apps/**   — scanned. apps/android has no Rust today; the desktop shell's
#               EXISTING forks are grandfathered per-file below (#211).
#   tools/**  — NOT scanned: dev tooling, not the product architecture
#               surface (verified: zero platform-cfg hits in tools/ at
#               main 63fb79e).
#
# Exemptions, in application order:
#   1. crates/platform/ — the rule's home.
#   2. windows_subsystem BY ATTRIBUTE NAME — the linker directive
#      #![cfg_attr(..., windows_subsystem = "windows")] is required by the
#      language at the bin crate root and forks no code path. Only the
#      attribute name is exempt: a cfg_attr carrying any OTHER attribute on
#      a platform predicate still flags. Not file-based, not crate-based.
#   3.（原「存量分叉按文件豁免」——**2026-09-21 全部销号，豁免清单为空**。）
#
#      daemon 侧 7 处 → PR #280；桌面壳 18 处 → #211 桌面壳批次。
#
#      中间挡路的 3 处「只挂在测试上的平台门」**没有开豁免**：建「指向目录
#      的链接」那个能力搬进了 crates/platform 的 test-support feature
#      （#287 / PR #329）。那张卡问的就是「能做到为什么要豁免」，答案是不
#      豁免——要往回加豁免之前，请先读一遍它。
#
#      现在 crates/** 与 apps/** 里**任何**平台分叉都必须走
#      crates/platform/，没有例外文件。加例外需要 issue 拍板。
VIOLATIONS_B2=$(grep -rn --include='*.rs' \
  -E '\bcfg(_attr)?\b.*\b(unix|windows|linux|macos|target_os|target_family|target_env)\b' \
  "$ROOT/crates" "$ROOT/apps" \
  | grep -v 'crates/platform/' \
  | grep -v 'windows_subsystem' \
  || true)

if [ -n "$VIOLATIONS_B2" ]; then
  echo "❌ B.2 VIOLATION: platform cfg found outside crates/platform/:"
  echo "$VIOLATIONS_B2"
  FAIL=1
else
  echo "   ✅ B.2: clean"
fi

# ── 多行扫描器（B.3 / G1 / G5 共用）────────────────────
#
# 为什么不用 grep：grep 逐行匹配，`DELETE\n  FROM device` 这种跨行写法看不到。
# perl -0777 把整个文件当一个字符串，正则里 \s 能跨过换行；行号用匹配起点之前
# 的换行数还原。macOS 与 ubuntu 都自带 perl。
#
# 用法：scan_files <perl 正则> <strip 注释 0|1> <flags> < NUL 分隔的文件清单
# 输出：<相对 ROOT 的路径>\t<行号>（同一行只记一次）
scan_files() {
  local re="$1" strip="$2" flags="$3"
  # xargs -r 不是 POSIX（BSD xargs 空输入也会跑一次 perl），所以先判空。
  local list
  list=$(mktemp)
  cat >"$list"
  if [ -s "$list" ]; then
    xargs -0 perl -0777 -e '
      my ($re, $strip, $flags, $root) = splice(@ARGV, 0, 4);
      my $qr = $flags =~ /i/ ? qr/$re/im : qr/$re/m;
      for my $f (@ARGV) {
        open(my $fh, "<", $f) or next;
        local $/; my $t = <$fh>; close $fh;
        # 注释行换成空串但保留换行（行号不漂）；注释里讲 HOME/plist 不算越界。
        $t =~ s{^[ \t]*(?://|/\*|\*(?:\s|\z)|<!--|\#(?![\[!]))[^\n]*}{}mg if $strip;
        # 与 B.2 同一条豁免：windows_subsystem 是语言要求写在 bin 根上的链接器
        # 指令，不分叉任何代码路径。
        $t =~ s{windows_subsystem\s*=\s*"windows"}{}g if $strip;
        my %seen;
        while ($t =~ /$qr/g) {
          my $ln = (substr($t, 0, $-[0]) =~ tr/\n//) + 1;
          next if $seen{$ln}++;
          (my $rel = $f) =~ s{^\Q$root\E/}{};
          print "$rel\t$ln\n";
        }
      }
    ' "$re" "$strip" "$flags" "$ROOT" <"$list"
  fi
  rm -f "$list"
}

# 文件清单（NUL 分隔）：list_files <目录...> -- <find 名字过滤...>
# 统一排除构建产物目录；不存在的目录直接跳过。
list_files() {
  local dirs=() expr=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    [ -d "$1" ] && dirs+=("$1")
    shift
  done
  shift || true
  local n
  for n in "$@"; do
    [ ${#expr[@]} -gt 0 ] && expr+=(-o)
    expr+=(-name "$n")
  done
  [ ${#dirs[@]} -eq 0 ] && return 0
  find "${dirs[@]}" \( -name target -o -name node_modules -o -name dist -o -name .svelte-kit \) -prune -o \
    -type f \( "${expr[@]}" \) -print0
}

# ── B.3: device rows are never hard-deleted ─────────

echo "==> B.3: no physical delete of device / backup_watermark rows (DEV-02)"

# DEV-02 (验收人 2026-09-17/09-18 拍板)：「本地不应该把这个设备的记录删除
# 掉」，以及「任何设备都不应该对其它设备的记录有影响，尤其是删除」。设备
# 记录只允许软删——`UPDATE device SET revoked = 1`，恢复信任只有配对流程
# 有权做（`unrevoke`）。
#
# 被删掉的那条路径是 DEV-01 的 `merge_device()`：它把资产改挂到新身份后
# `DELETE FROM device` + `DELETE FROM backup_watermark`，于是「这台设备
# 存在过」这个事实在设备表里蒸发。设备与身份 1:1 定下之后这条路径整个
# 不该存在（续旧账目 = 两个身份共享一份账，当场破 1:1）。
#
# 为什么是门禁而不是测试：语义靠人记会再漏——同形状的前例是
# `flowTriggerLock`（MOB-88 #204：7 个入口记住 5 个）。行为测试证明
# 「这次没删」，门禁证明「以后删不进来」。
#
# #1040：原先是逐行 grep，三种写法能绕过——`DELETE\n FROM device`（跨行）、
# `FROM "device"`（引号）、`FROM main.device`（schema 前缀）。现改为整文件
# 多行匹配：关键字之间允许任意空白/换行/Rust 字符串的行尾反斜杠续行，表名
# 允许引号（"" `` []、Rust 字符串里的 \"）与 schema 前缀。`device_token`、
# `devices` 这类前缀相同的表不误报（表名后不得再接字符）。
# 自测：tools/test-arch-check.sh（含「还原成逐行 grep 则三个样例全漏」的反证）。
B3_RE='DELETE(?:\s|\\)+FROM(?:\s|\\)+(?:(?:\\?["`\[])?\w+(?:\\?["`\]])?\s*\.\s*)?(?:\\?["`\[])?(?:device|backup_watermark)(?:\\?["`\]])?(?!\w)'
VIOLATIONS_B3=$(list_files "$ROOT/crates" -- '*.rs' '*.sql' | scan_files "$B3_RE" 0 i | sort || true)

if [ -n "$VIOLATIONS_B3" ]; then
  echo "❌ B.3 VIOLATION: 设备记录只能软删（UPDATE device SET revoked = 1）:"
  echo "$VIOLATIONS_B3" | awk -F'\t' '{print "   " $1 ":" $2}'
  FAIL=1
else
  echo "   ✅ B.3: clean"
fi

# ── G1 / G5：平台边界（存量不增）──────────────────

echo "==> G1/G5: platform boundary (shell stays platform-blind; platform code lives in crates/platform)"

# 依赖倒置（里程碑 #9「桌面架构收口」）：业务只在 crates/，平台差异只在
# crates/platform，桌面壳只做 UI 与托管。B.2 只能看到 Rust 里的 `cfg`，下面
# 两条补它看不到的部分。
#
# G1 — apps/desktop 不得：
#   · 判断平台：`@tauri-apps/plugin-os`、navigator.platform/userAgent、
#     process.platform、`"macos"`/`"windows"`/`"linux"` 字面量比较、
#     std::env::consts::OS/FAMILY，以及匹配某个平台的 OS 报错原文；
#   · 读 HOME / USERPROFILE / LANG / LC_ALL / LC_MESSAGES 环境变量；
#   · 拼 plist 路径（`.plist`、LaunchAgents）。
#   平台信息只能来自 adapter 或 daemon 返回的字段。
#   扫描范围：src/**（js/ts/svelte）与 src-tauri/src/**（rs）；测试文件
#   （*.test.js、testSetup.js）不扫——它们不是壳的产品代码。
#   注释行不算（解释「为什么不读 HOME」的注释不该被拦）。
#
# G5 — crates/platform 之外的 crates/** 与 apps/** 的 Rust 不得：
#   · std::os::{unix,windows,linux,macos,android}；
#   · std::env::consts::OS/FAMILY；
#   · 依赖平台专属 crate（Cargo.toml）：windows、windows-sys、winapi、
#     winreg、objc/objc2*、cocoa、core-foundation*、nix；
#   · Command::new 调平台专属命令行工具：launchctl、schtasks、powershell、
#     osascript、systemctl、xdg-open、taskkill、reg、explorer、pmset、open。
#   （`cfg` 属性本身仍归 B.2。）
#
# 存量：命中项登记在 tools/arch-allowlist.txt（文件 + 规则 + 计数 + 理由）。
# 登记数必须与命中数精确相等：多了 = 新增越界（红）；少了 = 登记已过期，
# 要把数字改小或删条目（红）——白名单因此只能缩。条目与计数相对基线分支
# 也不许升（见 ratchet 一段）。永久例外（[permanent] 段，#998 安装位置闸门、
# #999 防睡眠这类客观平台差异）不计入白名单，但新增永久例外同样要 issue 拍板。
G1_RE='@tauri-apps/plugin-os|navigator\.(?:platform|userAgent|userAgentData)\b|process\.platform|process\.env\.(?:HOME|USERPROFILE|LANG)\b|["'"'"'`](?:macos|windows|linux|darwin|win32)["'"'"'`]|(?i:access is denied|being used by another process)|env::(?:var|var_os)\(\s*"(?:HOME|USERPROFILE|LANG|LC_ALL|LC_MESSAGES)"|env::consts::(?:OS|FAMILY)|\.plist\b|LaunchAgents'
G5_RS_RE='std::os::(?:unix|windows|linux|macos|android)\b|env::consts::(?:OS|FAMILY)|Command::new\(\s*"(?:launchctl|schtasks|powershell(?:\.exe)?|osascript|systemctl|xdg-open|taskkill|reg(?:\.exe)?|explorer(?:\.exe)?|pmset|open)"\s*,?\s*\)'
G5_TOML_RE='^[ \t]*(?:windows(?:-sys)?|winapi|winreg|objc2?(?:-[\w-]+)?|cocoa|core-foundation(?:-sys)?|nix)[ \t]*[=.]'

HITS=$(mktemp)
trap 'rm -f "$HITS"' EXIT
{
  list_files "$ROOT/apps/desktop/src" -- '*.js' '*.mjs' '*.ts' '*.svelte' \
    | tr '\0' '\n' | { grep -vE '\.test\.(js|ts)$|/testSetup\.js$' || true; } | tr '\n' '\0' \
    | scan_files "$G1_RE" 1 '' | awk -F'\t' '{print "G1\t" $1 "\t" $2}'
  list_files "$ROOT/apps/desktop/src-tauri/src" -- '*.rs' \
    | scan_files "$G1_RE" 1 '' | awk -F'\t' '{print "G1\t" $1 "\t" $2}'
  { list_files "$ROOT/crates" "$ROOT/apps" -- '*.rs' \
      | tr '\0' '\n' | { grep -v '/crates/platform/' || true; } | tr '\n' '\0' \
      | scan_files "$G5_RS_RE" 1 ''
    list_files "$ROOT/crates" "$ROOT/apps" -- 'Cargo.toml' \
      | tr '\0' '\n' | { grep -v '/crates/platform/' || true; } | tr '\n' '\0' \
      | scan_files "$G5_TOML_RE" 1 ''
  } | awk -F'\t' '{print "G5\t" $1 "\t" $2}'
} | sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3n >"$HITS"

# 把白名单规范化为 TSV：段 \t 文件 \t 规则 \t 计数 \t 理由。出错时输出 ERR 行。
normalize_allow() { # <白名单文件>
  awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*(#|$)/ { next }
    /^\[ratchet\][ \t]*$/    { sect = "ratchet"; next }
    /^\[permanent\][ \t]*$/  { sect = "permanent"; next }
    {
      if (sect == "") { print "ERR\t第 " NR " 行在 [ratchet]/[permanent] 段之前"; next }
      f = trim($1); r = trim($2)
      if (sect == "ratchet") {
        if (NF < 4) { print "ERR\t第 " NR " 行格式应为 文件 | 规则 | 计数 | 理由"; next }
        c = trim($3); reason = trim($4)
        if (c !~ /^[0-9]+$/ || c + 0 < 1) { print "ERR\t第 " NR " 行计数必须是正整数：" c; next }
      } else {
        if (NF < 3) { print "ERR\t第 " NR " 行格式应为 文件 | 规则 | 理由"; next }
        c = "-"; reason = trim($3)
      }
      if (f == "" || r == "" || reason == "") { print "ERR\t第 " NR " 行有空字段"; next }
      print sect "\t" f "\t" r "\t" c "\t" reason
    }' "$1"
}

if [ "$REPORT_ONLY" = "1" ]; then
  # 只报告：打印全部命中 + 一份可直接粘进白名单的计数草稿，不判红。
  echo "   ℹ️  ARCH_REPORT_ONLY=1：只列出命中，不比对白名单"
  if [ -s "$HITS" ]; then
    awk -F'\t' '{print "   " $1 "  " $2 ":" $3}' "$HITS"
    echo "   —— 按 文件+规则 汇总（白名单草稿）——"
    awk -F'\t' '{k = $2 " | " $1; n[k]++} END {for (k in n) print "   " k " | " n[k]}' "$HITS" | sort
  else
    echo "   （无命中）"
  fi
else
  GATE_OUT=$(mktemp)
  ALLOW_N=$(mktemp)
  trap 'rm -f "$HITS" "$GATE_OUT" "$ALLOW_N"' EXIT
  if [ ! -f "$ALLOWLIST" ]; then
    echo "❌ G1/G5: 找不到白名单 ${ALLOWLIST#"$ROOT"/}（门禁不能在没有账本的情况下放行）"
    FAIL=1
  else
    normalize_allow "$ALLOWLIST" >"$ALLOW_N"
    # 命中 vs 白名单。
    awk -F'\t' '
      FILENAME == ARGV[1] {
        if ($1 == "ERR") { print "❌ G1/G5 白名单格式错误：" $2; bad = 1; next }
        key = $2 SUBSEP $3
        if (key in sect) { print "❌ G1/G5 白名单重复条目：" $2 " | " $3; bad = 1; next }
        sect[key] = $1; cnt[key] = $4; file[key] = $2; rule[key] = $3; next
      }
      {
        key = $2 SUBSEP $1
        actual[key]++
        lines[key] = lines[key] " " $3
      }
      END {
        for (key in actual) {
          if (!(key in sect)) {
            split(key, p, SUBSEP)
            print "❌ " p[2] " VIOLATION（未登记的新越界）：" p[1] " 行" lines[key]
            bad = 1
          } else if (sect[key] == "ratchet" && actual[key] > cnt[key]) {
            split(key, p, SUBSEP)
            printf "❌ %s VIOLATION（新增越界）：%s 登记 %d 处，实际 %d 处，行%s\n", p[2], p[1], cnt[key], actual[key], lines[key]
            bad = 1
          } else if (sect[key] == "ratchet" && actual[key] < cnt[key]) {
            split(key, p, SUBSEP)
            printf "❌ %s 白名单过期：%s 登记 %d 处，实际只剩 %d 处——把计数改小（或在清零时删条目）\n", p[2], p[1], cnt[key], actual[key]
            bad = 1
          }
        }
        for (key in sect) if (!(key in actual)) {
          printf "❌ %s 白名单过期：%s 已无命中（%s 段）——删掉这条\n", rule[key], file[key], sect[key]
          bad = 1
        }
        exit bad
      }' "$ALLOW_N" "$HITS" >"$GATE_OUT" && GATE_RC=0 || GATE_RC=$?
    if [ "$GATE_RC" -ne 0 ]; then
      cat "$GATE_OUT"
      FAIL=1
    else
      N_RATCHET=$(awk -F'\t' '$1=="ratchet"{s+=$4} END{print s+0}' "$ALLOW_N")
      N_PERM=$(awk -F'\t' '$1=="permanent"{n++} END{print n+0}' "$ALLOW_N")
      echo "   ✅ G1/G5: 无新增越界（白名单存量 ${N_RATCHET} 处，永久例外 ${N_PERM} 条）"
    fi

    # ratchet：白名单相对基线分支只许降、不许升。
    # 为什么要有基线：光「命中数 == 登记数」挡不住「顺手把白名单也一起加了」。
    # 把 PR 里的白名单和基线分支上的那份比，条目/计数变大、出现新的永久例外
    # 都报红——要放宽只能先在 issue 里拍板、改本脚本，不能悄悄改账本。
    ALLOW_REL="${ALLOWLIST#"$ROOT"/}"
    if [ "${ARCH_RATCHET_SKIP:-0}" = "1" ]; then
      echo "   ℹ️  ratchet: ARCH_RATCHET_SKIP=1，跳过基线比对"
    else
      BASE_REF="${ARCH_BASE_REF:-origin/main}"
      if BASE_TXT=$(git -C "$ROOT" show "$BASE_REF:$ALLOW_REL" 2>/dev/null); then
        BASE_N=$(mktemp)
        printf '%s\n' "$BASE_TXT" >"$BASE_N.raw"
        normalize_allow "$BASE_N.raw" >"$BASE_N"
        if awk -F'\t' -v base="$BASE_REF" '
          FILENAME == ARGV[1] { if ($1 != "ERR") { bs[$2 SUBSEP $3] = $1; bc[$2 SUBSEP $3] = $4 } next }
          $1 == "ERR" { next }
          {
            key = $2 SUBSEP $3
            if ($1 == "ratchet") {
              old = (key in bs && bs[key] == "ratchet") ? bc[key] : 0
              if ($4 + 0 > old + 0) { printf "❌ ratchet: %s | %s 计数 %d → %d（相对 %s 变大）\n", $2, $3, old, $4, base; bad = 1 }
            } else if (!(key in bs) || bs[key] != "permanent") {
              printf "❌ ratchet: 新增永久例外 %s | %s（需要 issue 拍板，不能直接加）\n", $2, $3; bad = 1
            }
          }
          END { exit bad }' "$BASE_N" "$ALLOW_N" >"$GATE_OUT"; then
          echo "   ✅ ratchet: 白名单相对 $BASE_REF 没有增加"
        else
          cat "$GATE_OUT"
          echo "❌ ratchet: 白名单只能缩不能增（条目、计数、永久例外都不许比 $BASE_REF 多）"
          FAIL=1
        fi
        rm -f "$BASE_N" "$BASE_N.raw"
      elif git -C "$ROOT" rev-parse --verify -q "$BASE_REF" >/dev/null 2>&1; then
        echo "   ℹ️  ratchet: $BASE_REF 上还没有 ${ALLOW_REL}（本卡首次引入），跳过基线比对"
      elif [ -n "${CI:-}" ]; then
        echo "❌ ratchet: CI 里取不到基线 ${BASE_REF}——拿不到基线就无法证明「只降不升」，按失败处理"
        echo "   （push 到 main 的场景请显式设 ARCH_RATCHET_SKIP=1；PR 请先 git fetch 基线分支）"
        FAIL=1
      else
        echo "   ⚠️  ratchet: 本地没有基线 ${BASE_REF}，已跳过（CI 会比对）。git fetch origin main 后重跑可本地验证"
      fi
    fi
  fi
fi

# ── Result ──────────────────────────────────────────

if [ $FAIL -eq 0 ]; then
  echo ""
  echo "✅ arch-check: all architecture rules passed"
  exit 0
else
  echo ""
  echo "❌ arch-check: $FAIL rule(s) violated"
  exit 1
fi
