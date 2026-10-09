#!/usr/bin/env bash
# REL-12（#711）：release.yml · finalize-manifest ·「Sign manifest entries (gated)」。
# 原样抽自 workflow 内嵌 bash；门控（HAS_UPDATE_KEY + manifest.json 存在）仍写在 workflow 的 if: 里。
#
# 输入（显式）：
#   TAG                 本次发布的 tag（job env）
#   UPDATE_SIGNING_KEY  tauri signer 私钥（只在本步 env 里出现）
#   RUNNER_TEMP         runner 每 job 的临时目录
#   artifacts/**（上一步 compose-desktop.sh 的产出 + 下载的产物）
# 输出：产物旁的 .sig；test tag 的 manifest.json、两份分端清单的 signature 字段。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${UPDATE_SIGNING_KEY:?UPDATE_SIGNING_KEY 未设置（本步 env）}"
: "${RUNNER_TEMP:?RUNNER_TEMP 未设置}"
cd "$(dirname "$0")/../.."

KEY="$RUNNER_TEMP/ppass-update.key"
SIGS="$RUNNER_TEMP/sigs"
# printf '%s' 逐字节还原（echo 的尾换行会让 tauri signer 报
# Invalid symbol——v0.2.1-test.1 实测踩坑，见 sign-android.sh）。
printf '%s' "$UPDATE_SIGNING_KEY" > "$KEY"
chmod 600 "$KEY"
mkdir -p "$SIGS"
# REL-10（#707）：要签的文件在**本步内**定位。每个 step 是独立 shell，
# 上一步（compose-desktop.sh）里的 APK_PATH / MAC_UPD 到这里是未定义——
# set -u 下直接 unbound variable，正式版分端清单因此签不了、传不上去。
# 目录可能不在（dispatch 只选了部分平台）：find 失败在 pipefail 下会杀掉整步，
# 这里按「没有这一端」处理——该不该有，已由上一步的 mac 门禁判过。
APK_PATH=$(find artifacts/android -maxdepth 1 -name 'P-Pass_*_android*.apk' 2>/dev/null | head -1 || true)
MAC_UPD=$(find artifacts/macos-arm64 -maxdepth 1 -name 'P-Pass_*_macos-arm64.app.tar.gz' 2>/dev/null | head -1 || true)
for f in "$APK_PATH" "$MAC_UPD"; do
  [ -f "$f" ] || continue
  # pin 版本，与 desktop pnpm-lock 的 @tauri-apps/cli@2.11.4 一致
  npx -y @tauri-apps/cli@2.11.4 signer sign -f "$KEY" -p "" "$f"
  cp "$f.sig" "$SIGS/"
done
# UPD-13（#660）：**正式版跳过**——那份是冻结件，签名已随文件冻结；
# 用本次资产的 .sig 去重签会把 0.9.0 的签名覆盖成对不上字节的新签名。
if [[ "$TAG" == *-test.* ]]; then
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
