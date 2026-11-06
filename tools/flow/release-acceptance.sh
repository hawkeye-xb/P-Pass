#!/usr/bin/env bash
# 发版前验收门禁（#1471 按版本验收）：候选版相对上一个正式版、用户看得见的改动，台账里都已验，且验过之后相关文件没再改。
#
#   release-acceptance.sh <台账 issue 号> [<候选 ref，默认 origin/main>]
#
# 判据（实现在 release-scope.sh --check，范围算法只在那一份）：
#   1. 范围 = 台账记下的起点（上一个正式 tag）..候选 ref 里 squash 或普通合并的 PR，acceptance-gate.sh classify 判为 ui / core / notes 的。
#   2. 每个 PR 都要在台账里、已勾 [x]，且它改过的文件在「验过的包..候选 ref」之间没再改过；不在台账里的（最后一个 test 包之后才合入）
#      也算待验。台账里还有没勾的项同样不放行。
# 输出：每个待验 / 待重验项一行。
# 退出码：0 清零 / 1 有待验项，或 gh / git 读不到（fail-closed，不当通过）/ 2 用法错误、ref 不存在。
#
# 已接进 release.yml（#1486，方案 docs/decisions/2026-11-06-release-acceptance-gate.md）：正式版发版时 plan-builds 按标题
# 「[验收] <正式 tag>」找台账，以 <台账号> <本次构建提交> 调本脚本，红了什么都不构建。owner 也可随时手动跑：
# just release-acceptance <台账号> [<候选 ref>]。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

LEDGER="${1:-}"
[[ "$LEDGER" =~ ^[0-9]+$ ]] || usage
[ "$#" -le 2 ] || usage
TO="${2:-origin/main}"
case "$TO" in -*) usage ;; esac

exec bash "${HERE}/release-scope.sh" --check --ledger "$LEDGER" --to "$TO"
