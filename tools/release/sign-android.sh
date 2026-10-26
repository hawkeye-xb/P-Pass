#!/usr/bin/env bash
# REL-12（#711）：release.yml · upload-android ·「Sign update manifest (UPD-01)」。
# 门控（清单文件存在）写在 workflow 的 if: 里；#1121 起密钥缺失不再跳过，而是失败。
#
# 输入（显式）：
#   TAG                 本次发布的 tag（job env），决定用哪个通道的密钥
#   UPDATE_SIGNING_KEY / UPDATE_SIGNING_KEY_TEST  tauri signer 私钥（base64 文本；只在本步
#                       env 里出现；#1121：正式与 test 通道各一把，见 update-key-lib.sh）
#   RUNNER_TEMP         runner 每 job 的临时目录（密钥文件与 .sig 收集目录放这里）
#   artifacts/android/P-Pass_*_android*.apk、artifacts/manifest*.json（上一步产出）
# 输出：APK 旁的 .sig；artifacts/manifest.json（若有）与 artifacts/manifest-android.json 的
#   signature 字段被填上。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${RUNNER_TEMP:?RUNNER_TEMP 未设置}"
cd "$(dirname "$0")/../.."

KEY="$RUNNER_TEMP/ppass-update.key"
SIGS="$RUNNER_TEMP/sigs"
APK=$(find artifacts/android -maxdepth 1 -name 'P-Pass_*_android*.apk' -exec basename {} \; | head -1)
# shellcheck source=tools/release/update-key-lib.sh
. tools/release/update-key-lib.sh
if [ -f "artifacts/android/$APK.sig" ]; then
  # #1151：复用的产物（reuse-artifact.sh）自带从 Latest 沿用的原签名——只验、不签，
  # 也就不需要私钥。已发布的字节没有第二次被签名的机会。
  verify_signed_files "$TAG" "artifacts/android/$APK"
else
  # rsign 私钥（base64 文本，tauri signer 格式）还原成文件；CI 非交互 → 空密码。
  # 签名走 tauri 官方 signer（minisign 格式，与 tauri-plugin-updater 验证端同源）。
  # #1121：按 TAG 选通道密钥（update-key-lib.sh；printf 逐字节还原的坑也在那里）。
  write_signing_key "$TAG" "$KEY"
  # #1121：签名器只从 tools/release/signer/ 的 lockfile 安装（锁哈希、不跑安装脚本），
  # 签名环境不执行现拉代码。版本仍是 2.11.4（signer 格式漂移会静默产出坏签名，UPD-01）。
  tools/release/signer.sh sign -f "$KEY" -p "" \
    "artifacts/android/$APK"
  rm -f "$KEY"
  # #1121：签完立刻用本通道公钥验——私钥与通道对不上当场失败。
  verify_signed_files "$TAG" "artifacts/android/$APK"
fi
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
