#!/usr/bin/env bash
# REL-07 / #872：test 通道——固定的滚动 prerelease `test-channel` 同时放**清单与安装包**
# （同 neovim 的 nightly tag）。客户端只读 releases/download/test-channel/<清单> 这一个静态文件，
# 清单里的下载链接也指向 test-channel 里的安装包：不调 GitHub API → 没有匿名限流、不需要 GH_TOKEN。
# test tag 自己的 release 保持 draft，只当构建记录，删不删都不影响任何客户端与流程。
#
# 每一端一份清单（#788② / #852，与正式版的分端清单一一对应，test 包只有清单地址与正式包不同）：
#   manifest-android.json  Android（upload-android；Android test 包读它）
#   manifest-macos.json    macOS（finalize-manifest；macOS test 包的插件 endpoint）
#   manifest-windows.json  Windows（finalize-manifest-windows；Windows test 包的插件 endpoint）
#   manifest.json          过渡期：老格式 Android 清单（upload-android），给 #852 之前装的 Android test 包
# 各端只覆盖自己那份，互不等待。test tag 按端发布（#852）：本次没构建的一端不调用本脚本，
# 它在通道里的清单与安装包保持原样（版本仍是上一次构建它的 test tag）。
#
# 用法：tools/release/point-test-channel.sh <本次清单文件> [安装包文件...]
#   安装包 = 清单里下载链接指向的文件，外加手动安装用的包（如 macOS 的 dmg）。一律 --clobber：
#   重跑同一个 tag 会重新构建，字节可能变，清单里的 sha256 跟的是本次的文件。
# 输入：TAG（job env）、GITHUB_REPOSITORY；gh 已登录（GH_TOKEN）。
#
# 顺序与不变量（任何时刻客户端读到的清单，其下载链接都可达）：
#   1. 重跑旧 tag 不许把指针往回拨：通道里同名清单已是更新版本 ⇒ 什么都不做。
#   2. 先传安装包；清单里每个下载链接都必须是 test-channel 里已有的文件，否则拒绝写清单。
#   3. 再覆盖清单。
#   4. 最后清理：删掉 test-channel 里**没有任何清单指向的版本**的安装包。按「被引用的版本」而不是
#      「被引用的文件」判，dmg 这类不进清单、但与当前版本配套的包才留得住；不带版本号的文件不动。
#   5. 删掉比被指向的最新版本还旧、且没被指向的 test 草稿（连同 tag）。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设置}"
SRC="${1:?用法：point-test-channel.sh <清单文件> [安装包文件...]}"
shift
NAME=$(basename "$SRC")
CH=test-channel
CH_BASE="https://github.com/${GITHUB_REPOSITORY}/releases/download/${CH}"

[[ "$TAG" == *-test.* ]] || { echo "::error::只有 test tag 才能移动 test-channel 指针（本次 ${TAG}）"; exit 1; }
[ -s "$SRC" ] || { echo "::error::${SRC} 不在或为空——拒绝把空清单写进 test-channel"; exit 1; }
for f in "$@"; do
  [ -s "$f" ] || { echo "::error::安装包 ${f} 不在或为空"; exit 1; }
done

if ! gh release view "$CH" >/dev/null 2>&1; then
  NOTES="${RUNNER_TEMP:-/tmp}/ch-notes.md"
  printf '%s\n' \
    "固定的 test 通道，勿删。test 包客户端只读本 release 里的各端清单，安装包也在这里；" \
    "每次 test 发布覆盖本端清单与安装包，并清掉没有清单指向的旧包（release.yml · REL-07 / #872）。" \
    "Fixed test channel - do not delete. Holds per-platform manifests and the installers they point to." > "$NOTES"
  gh release create "$CH" --prerelease --latest=false --target "$(git rev-parse HEAD)" \
    --title "test channel (rolling)" --notes-file "$NOTES"
fi

version_of() { node -p 'require(process.argv[1]).version' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }

# 1. 不回拨
NEW=$(version_of "$SRC")
CUR=""
CUR_FILE="${RUNNER_TEMP:-/tmp}/ch-current-${NAME}"
if gh release download "$CH" -p "$NAME" -O "$CUR_FILE" --clobber 2>/dev/null; then
  CUR=$(version_of "$CUR_FILE")
fi
if [ -n "$CUR" ] && [ "$CUR" != "$NEW" ] && \
   [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | tail -n1)" = "$CUR" ]; then
  echo "test-channel 的 ${NAME} 已指向更新的 ${CUR}（本次 ${NEW}）——不回拨"
  exit 0
fi

ch_assets() { gh release view "$CH" --json assets -q '.assets[].name'; }

# 2. 先传安装包，再核对清单里的每个下载链接
[ "$#" -eq 0 ] || gh release upload "$CH" "$@" --clobber
HAVE=$(ch_assets)
while IFS= read -r url; do
  [ -n "$url" ] || continue
  case "$url" in
    "$CH_BASE"/*) ;;
    *) echo "::error::${NAME} 的下载链接 ${url} 不在 test-channel 下——拒绝写清单"; exit 1 ;;
  esac
  if ! printf '%s\n' "$HAVE" | grep -qxF "${url##*/}"; then
    echo "::error::${NAME} 指向的 ${url##*/} 还不在 test-channel 里——拒绝写清单（客户端会 404）"; exit 1
  fi
done < <(node -e 'for (const p of Object.values(require(process.argv[1]).platforms || {})) console.log(p.url)' \
  "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")")

# 3. 覆盖清单
gh release upload "$CH" "$SRC" --clobber
echo "test-channel/${NAME} → ${NEW}: ${CH_BASE}/${NAME}"

# 4. 清理：被任一清单指向的版本才保留
KEEP_DIR="${RUNNER_TEMP:-/tmp}/ch-keep"
rm -rf "$KEEP_DIR"; mkdir -p "$KEEP_DIR"
KEEP=""
for m in $(ch_assets | grep -E '^manifest(-[a-z]+)?\.json$' || true); do
  gh release download "$CH" -p "$m" -O "$KEEP_DIR/$m" --clobber
  KEEP="$KEEP $(version_of "$KEEP_DIR/$m")"
done
for n in $(ch_assets | grep -E '^P-Pass_' || true); do
  v=${n#P-Pass_}; v=${v%%_*}
  case " $KEEP " in
    *" $v "*) ;;
    *) gh release delete-asset "$CH" "$n" --yes; echo "test-channel：删除没有清单指向的旧包 ${n}" ;;
  esac
done

# 5. 清理旧的 test 草稿（#872）：test tag 自己的 release 只是构建记录。版本没有被任何清单指向、
#    且比被指向的最新版本还旧的 test 草稿连同它的 tag 一起删——它既不是谁的下载来源，也不是
#    plan-builds 的基线。比最新被指向版本新的不动：那可能是正在跑、还没写指针的 test tag。
# shellcheck disable=SC2086 # KEEP 是空格分隔的版本列表，刻意拆分
NEWEST=$(printf '%s\n' $KEEP | sort -V | tail -n1)
for t in $(gh release list --limit 200 --json tagName,isDraft \
             -q '.[] | select(.isDraft and (.tagName | contains("-test."))) | .tagName'); do
  v=${t#v}
  case " $KEEP " in *" $v "*) continue ;; esac
  [ "$v" != "$NEWEST" ] && [ "$(printf '%s\n%s\n' "$v" "$NEWEST" | sort -V | tail -n1)" = "$NEWEST" ] || continue
  gh release delete "$t" --yes --cleanup-tag
  echo "删除旧的 test 草稿与 tag：${t}"
done
