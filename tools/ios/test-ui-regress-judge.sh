#!/usr/bin/env bash
# tools/ios/ui-regress.sh 判定部分的自测（#1458）：只认本例那次启动之后的日志、通过行要按顺序出现。
# 不要设备，几秒跑完：bash tools/ios/test-ui-regress-judge.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
J="$ROOT/tools/ios/ui-regress.sh"
RULES="$ROOT/tools/ios/ui-regress-rules.tsv"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # $1 期望 PASS|FAIL $2 用例 $3 日志 $4 开跑 epoch $5 说明
  local got
  got=$(bash "$J" judge "$RULES" "$2" "$3" "$4" | cut -f1)
  [ "$got" = "$1" ] || fail "$5：期望 $1，实际 $got（$(bash "$J" judge "$RULES" "$2" "$3" "$4" | cut -f2)）"
  echo "ok  $5 → $1"
}
iso() { python3 -I -c 'import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone().isoformat(timespec="milliseconds"))' "$1"; }
NOW=$(date +%s)
OLD=$((NOW - 600))

# 上一例（10 分钟前的进程）留下了通过行，本例进程没有 ⇒ 不许假绿。
cat >"$T/stale.log" <<EOF
$(iso "$OLD") process start: pid=100 version=0.11.0(1) appState=active
$(iso "$OLD") onboarding: decision shown
$(iso "$OLD") onboarding: photo access after prompt=full
$(iso "$NOW") process start: pid=200 version=0.11.0(1) appState=active
$(iso "$NOW") onboarding: decision shown
$(iso "$NOW") onboarding: photo access after prompt=none
EOF
expect FAIL DecisionScopeFull "$T/stale.log" "$NOW" "上一例的通过行不算"

# 本例进程里有，按顺序 ⇒ PASS。
cat >"$T/ok.log" <<EOF
$(iso "$OLD") process start: pid=100 version=0.11.0(1) appState=active
$(iso "$NOW") process start: pid=200 version=0.11.0(1) appState=active
$(iso "$NOW") onboarding: decision shown
$(iso "$NOW") onboarding: photo access after prompt=full
EOF
expect PASS DecisionScopeFull "$T/ok.log" "$NOW" "本例进程的通过行"

# 本例根本没启动（最后一个 process start 早于开跑）⇒ FAIL。
expect FAIL DecisionScopeFull "$T/ok.log" "$((NOW + 600))" "本例没有启动行"

# 顺序反了 ⇒ FAIL（设置页挑照片：第一次 picked 在决定页、早于 marked onboarded，不能当设置页那次）。
cat >"$T/order.log" <<EOF
$(iso "$NOW") process start: pid=300 version=0.11.0(1) appState=active
$(iso "$NOW") picked: 1 chosen
$(iso "$NOW") onboarding: marked onboarded via=pick
EOF
expect FAIL SettingsPick "$T/order.log" "$NOW" "决定页那次 picked 不算设置页的"
printf '%s picked: 1 chosen\n' "$(iso "$NOW")" >>"$T/order.log"
expect PASS SettingsPick "$T/order.log" "$NOW" "设置页再选一次"

# 未知用例、日志拉不回 ⇒ FAIL。
expect FAIL NoSuchCase "$T/ok.log" "$NOW" "判定表里没有的用例"
expect FAIL DecisionScopeFull "$T/missing.log" "$NOW" "日志拉不回"
echo "PASS: ui-regress 判定自测"
