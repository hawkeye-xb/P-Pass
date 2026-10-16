#!/usr/bin/env bash
# 把真机上的 P-Pass 配回本机正式桌面（/Applications/P-Pass.app 内置 daemon），并恢复用户的相册范围。sim-bg-task.sh 跑完自动调用。
#
#   tools/ios/restore-desktop-pairing.sh <范围备份.json> [设备标识]   # 配回正式桌面 + 恢复范围
#   tools/ios/restore-desktop-pairing.sh --delete-test-assets [设备标识] # 删掉手机里所有「PPass BGTest *」相册的照片 / 视频（要人点确认）
#
# 为什么需要：sim-bg-task.sh 每轮把手机配到自己起的临时 daemon（--ephemeral），跑完 daemon 就没了，
# 手机停在「配着一台不存在的电脑」，别的会话再用手机时 hello 全部超时；范围也被改成了测试相册。
# 范围备份 = sim-bg-task.sh 开跑前用 DEBUG 驱动（PPASS_BGTEST_SCOPE_EXPORT=1）导出的 {selected, known}。
# 怎么做（只做恢复需要的最少操作）：
#   1. 正式 daemon 的 IPC（ipc.token 在照片库目录里）`pairing.start` 取配对串（10 分钟有效，只在内存里）。
#   2. DEBUG 驱动 PPASS_BGTEST_PAIR_ONLY=1：先把范围清空 → 配对 → 只有当所选相册里**没有任何测试资源**时才恢复成备份的范围；
#      有交集（例如选了「最近项目」而测试照片还在图库里）就保持空范围并判失败——测试照片不能进用户真实的照片库。
#      这时先跑 --delete-test-assets（手机上会弹系统确认框，要人点「删除」），再重跑本脚本。
#   3. IPC 上允许 pending 里的那一台（同一台手机重新配对时桌面会直接接受，不出 pending）。
#   4. 判定：App 报告的范围与备份逐项一致；桌面 devices.list 里这台手机在线。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
ARG="${1:-}"
DEV="${2:-${PPASS_DEVICE:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}}"
TOKEN_FILE="${PPASS_DESKTOP_IPC_TOKEN:-$HOME/Pictures/P-Pass 家庭照片库/ipc.token}"
OUT="$IOS/build/restore-pairing/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
[ -n "$ARG" ] || { sed -n '4,5p' "$0"; exit 64; }

launch() { # $1 = 环境变量 JSON
  xcrun devicectl device process launch --device "$DEV" --terminate-existing --environment-variables "$1" \
    --json-output "$OUT/launch.json" "$BUNDLE_ID" >"$OUT/launch.log" 2>&1 || { cat "$OUT/launch.log"; exit 1; }
  APP_PID=$(jq -r '.result.process.processIdentifier' "$OUT/launch.json")
}
status_of() { # $1 = run；拉到本次 run、已 done 的 status.json 返回 0
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/e2e/status.json --destination "$OUT/status.json" >/dev/null 2>&1 \
    && [ "$(jq -r '.run // ""' "$OUT/status.json")" = "$1" ] && [ "$(jq -r '.done // false' "$OUT/status.json")" = true ]
}

if [ "$ARG" = --delete-test-assets ]; then
  RUN="delete-$(date +%s)"
  launch "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_DELETE_TEST:"1"}')"
  echo ">>> 手机上会弹「删除 N 项」的系统确认框，请在手机上点「删除」（3 分钟内）。"
  for _ in $(seq 1 90); do status_of "$RUN" && break; sleep 2; done
  jq -c . "$OUT/status.json" 2>/dev/null || true
  if [ "$(jq -r .step "$OUT/status.json" 2>/dev/null)" = deleted ] && [ "$(jq -r .remaining "$OUT/status.json")" = 0 ]; then
    echo "PASS: 测试相册与其中的照片 / 视频已删除（iOS 在「最近删除」里留 30 天，不属于任何可选相册）"
    exit 0
  fi
  echo "FAIL: 测试资源没删干净（没点确认？）"; exit 1
fi

SCOPE_FILE="$ARG"
jq -e '.selected | type == "array"' "$SCOPE_FILE" >/dev/null \
  || { echo "error: $SCOPE_FILE 不是有效的范围备份（要有 selected 数组）" >&2; exit 1; }
[ -s "$TOKEN_FILE" ] || { echo "error: 找不到正式桌面的 IPC token：${TOKEN_FILE}（P-Pass 桌面没在跑？）" >&2; exit 1; }

# shellcheck source=tools/ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
ipc_pair_qr "$TOKEN_FILE"
DESK_NODE=$(printf '%s' "$PAIR_QR" | sed -n 's/.*[?&]node=\([0-9a-f]\{8\}\).*/\1/p')
echo "==> 正式桌面（node ${DESK_NODE}…）配对串已取（不落盘）；范围备份：$(jq -r '.selected | length' "$SCOPE_FILE") 个相册"

RUN="restore-$(date +%s)"
launch "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN" --arg s "$(jq -c '{selected, known}' "$SCOPE_FILE")" \
  '{PPASS_E2E_DIR:"container", PPASS_E2E_PAIR_LINK:$l, PPASS_E2E_RUN:$r, PPASS_BGTEST_PAIR_ONLY:"1", PPASS_BGTEST_SCOPE_RESTORE:$s}')"
echo "  App pid=${APP_PID}（清空范围 → 配对 → 恢复范围）"
DONE=
for _ in $(seq 1 60); do
  if resp=$(ipc pairing.pending 2>/dev/null); then
    for n in $(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty'); do
      ipc pairing.confirm "$(jq -cn --arg n "$n" '{accept: true, node_id: $n}')" >/dev/null 2>&1 && echo "  桌面：已允许 ${n:0:8}…"
    done
  fi
  if status_of "$RUN"; then DONE=1; break; fi
  sleep 1
done
[ -n "$DONE" ] || { echo "FAIL: 60 秒内 App 没报告配对结局"; exit 1; }
cp "$OUT/status.json" "$OUT/restore-status.json"
[ "$(jq -r .step "$OUT/status.json")" = paired ] || { echo "FAIL: 配对失败：$(jq -r '.error // .pair_outcome' "$OUT/status.json")"; exit 1; }
FAIL=0
if [ "$(jq -r .scope_restored "$OUT/status.json")" != true ]; then
  echo "FAIL: 范围没有恢复（$(jq -r '.scope_error // "所选相册里还有 \(.scope_conflict) 个测试资源"' "$OUT/status.json")），现在是空范围。"
  echo "      先跑 tools/ios/restore-desktop-pairing.sh --delete-test-assets（要人点确认），再重跑本脚本。"
  FAIL=1
elif [ "$(jq -c '.selected | sort' "$OUT/status.json")" != "$(jq -c '.selected | sort' "$SCOPE_FILE")" ]; then
  echo "FAIL: 恢复后的范围与备份不一致"; FAIL=1
else
  echo "  范围已恢复，与备份逐项一致（$(jq -r '.selected | length' "$OUT/status.json") 个相册）"
fi

# 连得上看桌面一侧：devices.list 里本次启动后 last_seen 更新、presence=online 的那台（4271a0e6 起控制面每个请求一条连接，请求之间 connection 是 offline）。
STARTED_MS=$(( $(date +%s) * 1000 - 120000 ))
CONN=
for _ in $(seq 1 20); do
  sleep 2
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Library/Logs/ppass.log --destination "$OUT/ppass.log" >/dev/null 2>&1 || continue
  awk -v p="pid=${APP_PID} " 'index($0,"process start:") {on = index($0,p) > 0} on' "$OUT/ppass.log" > "$OUT/process.log"
  CONN=$(ipc devices.list 2>/dev/null | jq -r --argjson t "$STARTED_MS" \
    '[.result.devices[]? | select(.last_seen >= $t and .presence == "online")] | max_by(.last_seen) // empty | "\(.node_id[0:8])… connection=\(.connection) presence=\(.presence)"')
  [ -n "$CONN" ] && grep -q 'PAIRING_REPAIRED' "$OUT/process.log" && break
done
echo "--- 本进程日志 ---"; cat "$OUT/process.log"; echo "---"
[ -n "$CONN" ] || { echo "FAIL: 桌面一侧没看到这台手机在线"; FAIL=1; }
echo "  桌面一侧：${CONN:-无}"
[ "$FAIL" = 0 ] || exit 1
echo "PASS: 已配回正式桌面（node ${DESK_NODE}…），手机在线，范围与备份一致（测试资源不在范围内）"
