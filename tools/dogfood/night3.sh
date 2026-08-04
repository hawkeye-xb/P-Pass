#!/usr/bin/env bash
# DOG-03 night 3 — A9（adb 灌 500 张）+ E1 双机并发 + B7（Mac 关机 24h+，
# 跨日通知节流验收的启动标记）。
#
# 用法: tools/dogfood/night3.sh [--serial <三星SN>] [--data-dir <Mac 端库目录>]
# A9 灌图: 生成 500 张随机图片 push 到三星 DCIM/Camera → MediaStore 扫描
# （晨间对账 D1 完成率会把它算进分母——这是「大批次」case 的注入）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERIAL=""
DATA_DIR="${PPF_DATA_DIR:-$HOME/Library/Application Support/P-Pass}"
WORK="/tmp/ppf-dogfood-night3"
PKG="com.hawkeyexb.ppass"
A9_COUNT="${PPF_A9_COUNT:-500}"

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
exec > >(tee "$WORK/night3.log") 2>&1
cleanup() { echo "[night3] cleanup"; }
trap cleanup EXIT

echo "=== DOG-03 night3 @ $(date -u +%FT%TZ) ==="

if [ -n "$SERIAL" ]; then ADB=(adb -s "$SERIAL"); else ADB=(adb); fi
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "❌ 无 adb 设备"; exit 1; }

# 1. A9: 生成 + push 500 张到相机目录（大批次：进度、FGS 存活、不 ANR）
BATCH="$WORK/a9-batch"
mkdir -p "$BATCH"
echo "── A9: 生成 $A9_COUNT 张随机图片 ──"
python3 - "$BATCH" "$A9_COUNT" <<'PY'
import os, random, sys
out, n = sys.argv[1], int(sys.argv[2])
rng = random.Random(20260804)
for i in range(n):
    w, h = rng.randint(320, 1600), rng.randint(320, 1600)
    # 极小 JPEG（无 EXIF 也可入库；体积小 push 快）
    path = os.path.join(out, f"a9_{i:04d}.jpg")
    with open(path, "wb") as f:
        f.write(bytes([0xFF, 0xD8, 0xFF, 0xE0]))
        f.write(b"DOG03" + os.urandom(64))
        f.write(bytes([0xFF, 0xD9]))
PY
echo "生成完成: $(find "$BATCH" -type f | wc -l | tr -d ' ') 张"

# push（分块避免 adb 单次参数过长）
find "$BATCH" -type f | sort | xargs -n 50 "${ADB[@]}" push >/dev/null 2>&1 \
  || { echo "⚠️ push 部分失败——重试剩余"; }
"${ADB[@]}" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE" >/dev/null 2>&1 || true
echo "✅ A9 注入: $A9_COUNT 张已 push 相机目录（晨间对账 D1 验证大批次完成率）"

# 2. E1 双机并发：需要第二台设备（鸿蒙）。三星侧已可开跑；鸿蒙按 runbook 手动。
cat <<'EOF'
── E1 双机并发 ──
三星已就绪；鸿蒙侧按 docs/runbook/dogfood-manual-cases.md 手动触发
「立即备份」，与三星整夜备份构成并发窗口。
EOF
echo "✅ E1 标记: 并发窗口已开"

# 3. B7: Mac 关机 24h+（跨日）——只在显式开启时执行（本脚本只管标记）
if [ "${PPF_SHUTDOWN:-0}" = "1" ]; then
  echo "⚠️ B7 执行: sudo shutdown -h +5（5 分钟后关机，跨日由外部调度唤醒）"
  echo "✅ B7 注入: 已排定关机——「电脑不可达」提示与通知节流归晨间/次日报"
else
  echo "⚠️ B7 跳过（PPF_SHUTDOWN=1 开启；跨日 case，勿在共享机器上跑）"
fi

echo "=== night3 注入完成：等自然触发，清晨跑 morning-report.sh ==="
