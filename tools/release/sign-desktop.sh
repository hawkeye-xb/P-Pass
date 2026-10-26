#!/usr/bin/env bash
# REL-12（#711）：release.yml · finalize-manifest / finalize-manifest-windows ·「Sign manifest entries (gated)」。
# 门控（manifest.json 存在）写在 workflow 的 if: 里；#1121 起密钥缺失不再跳过，而是失败。
#
# 输入（显式）：
#   TAG                 本次发布的 tag（job env）
#   UPDATE_SIGNING_KEY / UPDATE_SIGNING_KEY_TEST  tauri signer 私钥（只在本步 env 里出现；
#                       #1121：正式与 test 通道各一把，按 TAG 选，见 update-key-lib.sh）
#   RUNNER_TEMP         runner 每 job 的临时目录
#   artifacts/**（上一步 compose-desktop.sh 的产出 + 下载的产物）
# 输出：产物旁的 .sig；test tag 的 manifest.json、各分端清单的 signature 字段。
# #788②：Windows 安装包与 manifest-windows.json 走同一把密钥、同一个 signer——哪个 job
# 调用，就只签这个 job 里在场的产物与清单（不在场的端一律跳过）。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${RUNNER_TEMP:?RUNNER_TEMP 未设置}"
cd "$(dirname "$0")/../.."

KEY="$RUNNER_TEMP/ppass-update.key"
SIGS="$RUNNER_TEMP/sigs"
# printf '%s' 逐字节还原（echo 的尾换行会让 tauri signer 报
# Invalid symbol——v0.2.1-test.1 实测踩坑，见 sign-android.sh）。
# shellcheck source=tools/release/update-key-lib.sh
. tools/release/update-key-lib.sh
mkdir -p "$SIGS"
# REL-10（#707）：要签的文件在**本步内**定位。每个 step 是独立 shell，
# 上一步（compose-desktop.sh）里的 APK_PATH / MAC_UPD 到这里是未定义——
# set -u 下直接 unbound variable，正式版分端清单因此签不了、传不上去。
# 目录可能不在（dispatch 只选了部分平台）：find 失败在 pipefail 下会杀掉整步，
# 这里按「没有这一端」处理——该不该有，已由上一步的 mac 门禁判过。
APK_PATH=$(find artifacts/android -maxdepth 1 -name 'P-Pass_*_android*.apk' 2>/dev/null | head -1 || true)
MAC_UPD=$(find artifacts/macos-arm64 -maxdepth 1 -name 'P-Pass_*_macos-arm64.app.tar.gz' 2>/dev/null | head -1 || true)
WIN_EXE=$(find artifacts/windows-x64-installer -maxdepth 1 -name 'P-Pass_*_x64-setup.exe' 2>/dev/null | head -1 || true)
for f in "$APK_PATH" "$MAC_UPD" "$WIN_EXE"; do
  [ -f "$f" ] || continue
  if [ -f "$f.sig" ]; then
    # #1151：复用的产物自带从 Latest 沿用的原签名（reuse-artifact.sh）——只验、不签，
    # 已发布的字节没有第二次被签名的机会。
    verify_signed_files "$TAG" "$f"
    cp "$f.sig" "$SIGS/"
    continue
  fi
  [ -f "$KEY" ] || write_signing_key "$TAG" "$KEY"
  # #1121：签名器只从 tools/release/signer/ 的 lockfile 安装（锁哈希、不跑安装脚本）
  tools/release/signer.sh sign -f "$KEY" -p "" "$f"
  # #1121：签完立刻用本通道公钥验——私钥与通道对不上（比如 test 包签成了正式密钥）当场失败。
  verify_signed_files "$TAG" "$f"
  cp "$f.sig" "$SIGS/"
done
rm -f "$KEY"
# UPD-13（#660）：**正式版跳过**——那份是冻结件，签名已随文件冻结；
# 用本次资产的 .sig 去重签会把 0.9.0 的签名覆盖成对不上字节的新签名。
if [[ "$TAG" == *-test.* ]] && [ -f artifacts/manifest.json ]; then
  node tools/make-update-manifest.mjs \
    --sign artifacts/manifest.json --sig-dir "$SIGS"
fi
# UPD-13：分端清单同样要签（同一把密钥、同一批 .sig）。
if [ -f artifacts/manifest-android.json ]; then
  node tools/make-update-manifest.mjs \
    --sign artifacts/manifest-android.json --sig-dir "$SIGS"
fi
if [ -f artifacts/manifest-macos.json ]; then
  node tools/make-update-manifest.mjs \
    --sign artifacts/manifest-macos.json --sig-dir "$SIGS"
fi
if [ -f artifacts/manifest-windows.json ]; then
  node tools/make-update-manifest.mjs \
    --sign artifacts/manifest-windows.json --sig-dir "$SIGS"
fi
