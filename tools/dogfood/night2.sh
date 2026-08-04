#!/usr/bin/env bash
# DOG-03 night 2 — 前半夜 B1（Mac 睡眠独占）+ 后半夜 A1（滑杀 App）+
# A3（重启手机不打开 App 的周期任务幸存）恢复验证。
#
# 用法: tools/dogfood/night2.sh [--serial <三星SN>] [--data-dir <Mac 端库目录>]
# 前置: 三星 adb 已连接；Mac 端 daemon 常驻。
# ⚠️ B1 会让 Mac 睡眠——本脚本应在可无人值守的机器上跑（ssh 驱动）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERIAL=""
DATA_DIR="${PPF_DATA_DIR:-$HOME/Library/Application Support/P-Pass}"
WORK="/tmp/ppf-dogfood-night2"
PKG="com.hawkeyexb.ppass"

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
exec > >(tee "$WORK/night2.log") 2>&1
cleanup() { echo "[night2] cleanup"; }
trap cleanup EXIT

echo "=== DOG-03 night2 @ $(date -u +%FT%TZ) ==="

if [ -n "$SERIAL" ]; then ADB=(adb -s "$SERIAL"); else ADB=(adb); fi
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "❌ 无 adb 设备"; exit 1; }

# 1. 前半夜 B1：Mac 睡眠 20 分钟（可配 PPF_B1_MINUTES），期间三星自然备份
B1_MIN="${PPF_B1_MINUTES:-20}"
echo "── B1: Mac 睡眠 ${B1_MIN} 分钟（前半夜独占）──"
pmset sleepnow 2>/dev/null || { echo "⚠️ 无法触发睡眠（非 Mac/无权限）——B1 跳过，继续 A1/A3"; }
if [ -n "$(command -v caffeinate)" ]; then
  # 睡眠期间无法执行——实际编排里 B1 由外部调度（ssh 定时唤醒）。
  # 这里只做前置标记：晨间对账验证「睡眠中手机备份在醒后收敛」。
  echo "✅ B1 标记: 睡眠注入窗口已开（$(date +%FT%T)）——醒后由 morning-report 验证重试收敛"
fi

# 2. 后半夜 A1：滑杀 App（不留前台），验证 4h 周期任务仍触发
echo "── A1: 滑杀 App（adb am force-stop）──"
"${ADB[@]}" shell am force-stop "$PKG"
echo "✅ A1 注入: $PKG 已 force-stop（晨间对账验证周期任务仍推进水位）"

# 3. A3：重启手机（可选，--reboot 显式开启）——周期任务注册幸存性
if [ "${PPF_REBOOT:-0}" = "1" ]; then
  echo "── A3: 重启手机（不打开 App）──"
  "${ADB[@]}" reboot
  echo "✅ A3 注入: 已 reboot，等开机后晨间对账验证"
else
  echo "⚠️ A3 跳过（PPF_REBOOT=1 开启真重启；重启会中断 adb 会话）"
fi

echo "=== night2 注入完成：等自然触发，清晨跑 morning-report.sh ==="
