#!/usr/bin/env bash
# DOG-03 morning report — D1 每晚对账：三星 MediaStore 数 vs daemon 该
# 设备资产数 → 完成率日报（gate 读数本体）；水位推进检查（不推进亮红）。
#
# 用法: tools/dogfood/morning-report.sh [--serial <三星SN>] [--data-dir <库>]
#       [--since <unix_ms>] [--expect-stall <设备名>] [--out <md 路径>]
# 数据源: sqlite 直查占位（DOG-01 device.watermarks IPC 合并后切换——
#         日报将改用 ipc 查询，脚本形态不变）。
# 输出: markdown 日报 → stdout + --out 指定路径（默认 data_dir/dogfood-reports/）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERIAL=""
DATA_DIR="${PPF_DATA_DIR:-$HOME/Library/Application Support/P-Pass}"
SINCE_MS=""
EXPECT_STALL=""
OUT=""
PKG="com.hawkeyexb.ppass"
NOW_MS=$(( $(date +%s) * 1000 ))

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --since) SINCE_MS="$2"; shift 2 ;;
    --expect-stall) EXPECT_STALL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

DB="$DATA_DIR/.ppf/index.sqlite"
[ -f "$DB" ] || { echo "❌ 无 index.sqlite: $DB（daemon 未初始化？）"; exit 1; }

if [ -n "$SERIAL" ]; then ADB=(adb -s "$SERIAL"); else ADB=(adb); fi
if "${ADB[@]}" get-state >/dev/null 2>&1; then
  HAVE_ADB=1
else
  HAVE_ADB=0
  echo "⚠️ adb 不可达——MediaStore 侧缺失，完成率按 daemon 侧口径报"
fi

# ── 1. MediaStore 侧（三星）──
media_count=0
if [ "$HAVE_ADB" = "1" ]; then
  img=$("${ADB[@]}" shell content query --uri content://media/external/images/media --projection _id 2>/dev/null | grep -c '^Row:' || true)
  vid=$("${ADB[@]}" shell content query --uri content://media/external/video/media --projection _id 2>/dev/null | grep -c '^Row:' || true)
  media_count=$((img + vid))
fi

# ── 2. daemon 侧（sqlite 直查占位）──
# 设备名 → node_id 映射（配对时手机自报名）；macOS bash 3.2 无 mapfile，
# 且管道 while 跑在子 shell（变量不回传）→ 用进程替换 <( ... )。
report_rows=""
worst=0
stall_red=0
counterproof_hit=0
while IFS='|' read -r name node_hex; do
  [ -z "$name" ] && continue
  assets=$(sqlite3 "$DB" "SELECT COUNT(*) FROM asset WHERE src_device = x'$node_hex'" 2>/dev/null || echo 0)
  wm=$(sqlite3 "$DB" "SELECT COALESCE(MAX(updated_at),0) FROM backup_watermark WHERE node_id = x'$node_hex'" 2>/dev/null || echo 0)
  wm=${wm:-0}
  # 完成率（MediaStore 分母存在才报）
  rate="—"
  if [ "$HAVE_ADB" = "1" ] && [ "$media_count" -gt 0 ]; then
    rate=$(awk -v a="$assets" -v m="$media_count" 'BEGIN { printf "%.1f%%", a/m*100 }')
  fi
  # 水位推进：--since 之后必须有更新。wm=0（从未备份过）不算「未推进」
  # ——没有基线，D1 口径里它是「从未备份」而非「停滞」。
  stall=""
  if [ -n "$SINCE_MS" ] && [ "$wm" -gt 0 ] && [ "$wm" -lt "$SINCE_MS" ]; then
    stall="🔴 水位未推进"
    stall_red=1
  fi
  # 反证模式：--expect-stall <name> 的预期红设备——出现 stall 即反证成立
  # （该设备豁免，不计入 stall_red；其余设备 stall 仍是真问题）
  exp=""
  if [ "$name" = "$EXPECT_STALL" ] && [ -n "$stall" ]; then
    exp="（反证成立：预期不推进 ✅）"
    counterproof_hit=1
  elif [ -n "$stall" ]; then
    stall_red=1
  fi
  row=$(printf '| %s | %s | %d | %s | %s %s %s |' "$name" "${node_hex:0:12}…" "$assets" "$rate" "$stall" "$exp" "$( [ "$wm" -gt 0 ] && date -r $((wm/1000)) '+%m-%d %H:%M' || echo '—')")
  report_rows="$report_rows
$row"
done < <(sqlite3 "$DB" "SELECT name || '|' || hex(node_id) FROM device WHERE revoked=0 ORDER BY paired_at")

# ── 3. 组装日报 ──
REPORT="""# P-Pass 狗粮日报 $(date '+%Y-%m-%d')（DOG-03 morning-report）

生成时间: $(date -u +%FT%TZ)
数据源: sqlite 直查（DOG-01 device.watermarks 合并后切换 IPC）

## D1 对账

| 设备 | node_id | daemon 资产数 | 完成率（vs MediaStore ${media_count}） | 水位/备注 |
|---|---|---|---|---|
$report_rows

## 结论

- 水位推进: $([ "$stall_red" = "1" ] && echo '🔴 有设备未推进——gate 不通过' || echo '✅ 全部推进（或未设 --since）')
- 完成率: $([ "$HAVE_ADB" = "1" ] && [ "$media_count" -gt 0 ] && echo '见上表（分母=当前 MediaStore 扫描范围）' || echo '⚠️ MediaStore 侧缺失，未计算')
"""

# ── 反证模式退出码：预期红设备没红 = 反证失败（非零）──
if [ -n "$EXPECT_STALL" ]; then
  echo "$REPORT"
  if [ "$counterproof_hit" = "1" ] && [ "$stall_red" = "0" ]; then
    echo "✅ 反证成立：$EXPECT_STALL 水位未推进且已亮红（其余设备正常）"
    exit 0
  elif [ "$counterproof_hit" = "1" ]; then
    echo "⚠️ 反证部分成立，但其他设备也 stall——gate 不通过"
    exit 1
  else
    echo "⚠️ 反证失败：$EXPECT_STALL 未出现水位不推进（预期红没红）"
    exit 1
  fi
fi

echo "$REPORT"
if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  echo "$REPORT" > "$OUT"
  echo "日报已存: $OUT"
elif [ -d "$DATA_DIR" ]; then
  mkdir -p "$DATA_DIR/dogfood-reports"
  RP="$DATA_DIR/dogfood-reports/$(date '+%Y%m%d').md"
  echo "$REPORT" > "$RP"
  echo "日报已存: $RP"
fi
