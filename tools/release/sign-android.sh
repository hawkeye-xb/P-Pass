#!/usr/bin/env bash
# REL-12（#711）：release.yml · upload-android ·「Sign update manifest (UPD-01, gated)」。
# 原样抽自 workflow 内嵌 bash；门控（HAS_UPDATE_KEY + 清单文件存在）仍写在 workflow 的 if: 里。
#
# 输入（显式）：
#   UPDATE_SIGNING_KEY  tauri signer 私钥（base64 文本；只在本步 env 里出现）
#   RUNNER_TEMP         runner 每 job 的临时目录（密钥文件与 .sig 收集目录放这里）
#   artifacts/android/P-Pass_*_android*.apk、artifacts/manifest*.json（上一步产出）
# 输出：APK 旁的 .sig；artifacts/manifest.json（若有）与 artifacts/manifest-android.json 的
#   signature 字段被填上。
set -euo pipefail
: "${UPDATE_SIGNING_KEY:?UPDATE_SIGNING_KEY 未设置（本步 env）}"
: "${RUNNER_TEMP:?RUNNER_TEMP 未设置}"
cd "$(dirname "$0")/../.."

KEY="$RUNNER_TEMP/ppass-update.key"
SIGS="$RUNNER_TEMP/sigs"
APK=$(find artifacts/android -maxdepth 1 -name 'P-Pass_*_android*.apk' -exec basename {} \; | head -1)
# rsign 私钥（base64 文本，tauri signer 格式）还原成文件；CI
# 非交互 → 空密码。签名走 tauri 官方 signer（minisign 格式，
# 与 tauri-plugin-updater 验证端同源）。
# ⚠️ echo 会追加尾换行，tauri signer 的 base64 解码不 trim →
#   Invalid symbol 10 at offset N（N=key 字节数）；必须 printf '%s'
#   逐字节还原（v0.2.1-test.1 实测踩坑）。
printf '%s' "$UPDATE_SIGNING_KEY" > "$KEY"
chmod 600 "$KEY"
# UPD-01 返工：pin 版本（与 desktop pnpm-lock 的 @tauri-apps/cli@2.11.4
# 一致）——裸 npx @tauri-apps/cli 每次拉最新，signer 格式漂移会静默
# 产出坏签名。
npx -y @tauri-apps/cli@2.11.4 signer sign -f "$KEY" -p "" \
  "artifacts/android/$APK"
mkdir -p "$SIGS"
cp artifacts/android/*.sig "$SIGS/"
# UPD-15：正式 tag 下本 job **不产出** artifacts/manifest.json（动态清单只给
# test 通道）——文件不在就跳过签名，否则 --sign 直接 ENOENT 把整步判红
# （2026-10-05 v2026.10.2 实测：签名步因此红，APK/manifest 都上传不了）。
if [ -f artifacts/manifest.json ]; then
  node tools/make-update-manifest.mjs \
    --sign artifacts/manifest.json --sig-dir "$SIGS"
fi
# UPD-13：分端清单同样要签（同一把密钥、同一批 .sig）。
if [ -f artifacts/manifest-android.json ]; then
  node tools/make-update-manifest.mjs \
    --sign artifacts/manifest-android.json --sig-dir "$SIGS"
fi
