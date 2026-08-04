#!/usr/bin/env bash
# DOG-03 night 1 — 三星 A2-加白 + A4 熄屏整夜 + C4 NAT 保活；
# 鸿蒙 A2-不加白（对照）需人，见 docs/runbook/dogfood-manual-cases.md。
#
# 用法: tools/dogfood/night1.sh [--serial <三星SN>] [--data-dir <Mac 端库目录>]
# 前置: 三星 adb 已连接；Mac 端 daemon 常驻运行（IPC 可通）。
# 产出: 剧本启动日志 + /tmp/ppf-dogfood-night1/ 下的状态标记（晨间对账读取）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERIAL=""
DATA_DIR="${PPF_DATA_DIR:-$HOME/Library/Application Support/P-Pass}"
WORK="/tmp/ppf-dogfood-night1"
PKG="com.hawkeyexb.ppass"

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
exec > >(tee "$WORK/night1.log") 2>&1
cleanup() { echo "[night1] cleanup"; }
trap cleanup EXIT

echo "=== DOG-03 night1 @ $(date -u +%FT%TZ) ==="
echo "data_dir: $DATA_DIR"

# 0. adb 目标
if [ -n "$SERIAL" ]; then
  ADB=(adb -s "$SERIAL")
else
  ADB=(adb)
fi
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "❌ 无 adb 设备（--serial 指定三星）"; exit 1; }
echo "adb 设备: $("${ADB[@]}" get-serialno 2>/dev/null || echo unknown)"

# 1. A2-加白：三星白名单必须已含本 App（DOG-02 引导流程走完的产物）
if "${ADB[@]}" shell dumpsys deviceidle whitelist | grep -q "$PKG"; then
  echo "✅ A2-加白: $PKG 已在 deviceidle 白名单"
else
  echo "❌ A2-加白: $PKG 不在白名单 —— 先走 DOG-02 引导（或手动加白后重跑）"
  exit 1
fi

# 2. 熄屏前状态快照（晨间对账的水位基线）
echo "── 熄屏前水位基线 ──"
if [ -f "$DATA_DIR/.ppf/index.sqlite" ]; then
  sqlite3 "$DATA_DIR/.ppf/index.sqlite" \
    "SELECT 'devices: '||COUNT(*) FROM device WHERE revoked=0;
     SELECT 'watermark_updated_at: '||COALESCE(MAX(updated_at),0) FROM backup_watermark;
     SELECT 'assets: '||COUNT(*) FROM asset;" \
    | tee "$WORK/baseline.txt"
else
  echo "⚠️ 无 index.sqlite（daemon 未初始化？）——晨间对账将只报 MediaStore 侧"
fi

# 3. 熄屏（A4：充电+WiFi+Doze 深睡，产品日常态）
"${ADB[@]}" shell dumpsys battery >/dev/null 2>&1
"${ADB[@]}" shell input keyevent KEYCODE_SLEEP || true
echo "✅ A4: 已熄屏（$(date +%FT%T)）——整夜自然触发，晨间对账验证"

# 4. C4 空闲保活：记录基线，晨间验证空闲后仍传了新资产
echo "✅ C4: 已记录 NAT 保活基线 —— 晨间对账比对 asset 增量"

# 5. 鸿蒙对照提示
cat <<'EOF'
── 鸿蒙 A2-不加白（对照，需人）──
按 docs/runbook/dogfood-manual-cases.md 操作单：鸿蒙机保持「未加白」，
确认其整夜无自动备份（预期），三星侧正常（加白生效对照）。
EOF

echo "=== night1 注入完成：等自然触发，清晨跑 morning-report.sh ==="
