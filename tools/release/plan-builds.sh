#!/usr/bin/env bash
# #838：每一端「构建」还是「复用 Latest 的产物」——构建一次、到处复用（build once, promote）。
#
# 本质：同一个版本号只能对应同一份产物。正式 tag 上某端的版本号（release/versions.json）
# 与 Latest 正式版里该端清单的 version 相同 ⇒ 该端没有要发的新东西，直接复用 Latest 的
# 安装包；重新构建只会造出「同号不同物」。
#
# 判定（任何一条拿不准都判「构建」——宁可多构建，不可错复用）：
#   正式 tag：
#   - 没有 Latest、Latest 就是本 tag（补跑）、Latest 缺该端清单或安装包：构建。
#   - 该端版本号 == Latest 该端清单的 version：复用。
#   - 两端都判「复用」：报错退出——两端都没有新版本，这次正式 tag 没有可发布的东西。
#   test tag（#852：test 通道镜像正式版的按端发布）：版本号就是 tag 名、每次都变，不能按
#   版本号判，改按「该端的输入自上一次 test 发布以来变没变」判。
#   - 基线 = test-channel 里该端分端清单的 version 对应的 tag（= 该端测试机上正装着的那一版；
#     正常就是上一个 test tag；上次该端构建失败时是更早那个——那段改动不会被漏掉）。
#   - 基线拿不到（清单不在 / 读不出 / tag 不存在 / 不是 HEAD 的祖先 / 就是本 tag）或 diff 失败：构建。
#   - 改动路径分类（反向 allowlist，同 tools/ci-needs-full-lane.sh：没列出的一律算两端）：
#       docs/ cards/ .claude/ *.md                                  不影响产物
#       apps/android/、tools/build-android-iroh-blobs-bridge.sh      只算 Android
#       apps/desktop/、tools/bundle-macos.sh、tools/bundle-desktop-macos.sh、tools/fetch-ffmpeg.sh
#                                                                   只算桌面
#       其余（crates/、Cargo.*、assets/、release/、tools/、.github/ …） 两端
#   - 没改动的一端判 skip：不构建、也不复用（不复制任何产物），test-channel 里它的清单不动。
#   - 两端都是 skip：报错退出——这次 test tag 没有可发布的东西。
#
# 输入：TAG；当前目录 = 检出的仓库（读 release/versions.json；test tag 要完整历史与 tag）；
#   gh 已登录（GH_TOKEN）。
# 输出（追加到 $GITHUB_OUTPUT，未设置时打印到 stdout）：
#   android=build|reuse|skip  macos=build|reuse|skip  reuse_from=<Latest tag 或空>
#   android_version=<号>  macos_version=<号>
#   （reuse 只出现在正式 tag，skip 只出现在 test tag。）
# 被复用的一端若在 Latest 之后改过会影响产物的构建脚本，打 ::warning::（不阻断：
# 改动要等该端下次涨号才会生效）。
set -euo pipefail
: "${TAG:?TAG 未设置}"
cd "$(dirname "$0")/../.."
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

emit() { printf '%s=%s\n' "$1" "$2" >> "$OUT"; }

ANDROID_VER=$(jq -r .android release/versions.json)
MACOS_VER=$(jq -r .desktop release/versions.json)
emit android_version "$ANDROID_VER"
emit macos_version "$MACOS_VER"

if [[ "$TAG" == *-test.* ]]; then
  # test_base <清单名...>：test-channel 里该端清单的 version 对应的 tag（第一个读得到的为准）。
  test_base() {
    local m v
    for m in "$@"; do
      v=$(gh release download test-channel -p "$m" -O - 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)
      if [ -n "$v" ]; then echo "v${v#v}"; return; fi
    done
  }
  # 改动路径 → 影响哪一端：android / desktop / both / none（分类见文件头）。
  classify() {
    case "$1" in
      docs/* | cards/* | .claude/* | *.md) echo none ;;
      apps/android/* | tools/build-android-iroh-blobs-bridge.sh) echo android ;;
      apps/desktop/* | tools/bundle-macos.sh | tools/bundle-desktop-macos.sh | tools/fetch-ffmpeg.sh) echo desktop ;;
      *) echo both ;;
    esac
  }
  # decide_test <端> <android|desktop> <清单名...>
  decide_test() {
    local end="$1" kind="$2"; shift 2
    local base changed f k
    base=$(test_base "$@")
    if [ -z "$base" ]; then
      echo "${end}：test-channel 里没有可读的该端清单 ⇒ 构建" >&2; echo build; return
    fi
    if [ "$base" = "$TAG" ]; then
      echo "${end}：test-channel 已指向本 tag（补跑）⇒ 构建" >&2; echo build; return
    fi
    if ! git rev-parse -q --verify "${base}^{commit}" >/dev/null; then
      echo "${end}：基线 ${base} 在仓库里不存在 ⇒ 构建" >&2; echo build; return
    fi
    if ! git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
      echo "${end}：基线 ${base} 不是本次提交的祖先 ⇒ 构建" >&2; echo build; return
    fi
    if ! changed=$(git diff --name-only "$base" HEAD --); then
      echo "${end}：git diff ${base} HEAD 失败 ⇒ 构建" >&2; echo build; return
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      k=$(classify "$f")
      if [ "$k" = both ] || [ "$k" = "$kind" ]; then
        echo "${end}：自 ${base} 起改了 ${f}（${k}）⇒ 构建" >&2; echo build; return
      fi
    done <<<"$changed"
    echo "${end}：自 ${base} 起没有影响该端的改动 ⇒ 不构建，test-channel 里该端清单不动" >&2
    echo skip
  }
  # 过渡期：#852 之前 test-channel 只有老格式 manifest.json，它就是 Android 的清单。
  ANDROID=$(decide_test android android manifest-android.json manifest.json)
  MACOS=$(decide_test macos desktop manifest-macos.json)
  if [ "$ANDROID" = skip ] && [ "$MACOS" = skip ]; then
    echo "::error::test tag ${TAG}：两端自上一次 test 发布以来都没有影响产物的改动——这次没有可发布的东西。"
    exit 1
  fi
  emit android "$ANDROID"; emit macos "$MACOS"; emit reuse_from ""
  exit 0
fi

LATEST=$(gh release view --json tagName -q .tagName 2>/dev/null || true)
if [ -z "$LATEST" ] || [ "$LATEST" = "$TAG" ]; then
  echo "没有可复用的 Latest（Latest=${LATEST:-无}）：两端都构建"
  emit android build; emit macos build; emit reuse_from ""
  exit 0
fi
ASSETS=$(gh release view "$LATEST" --json assets -q '.assets[].name' 2>/dev/null || true)

# decide <端> <本次版本号> <清单名> <安装包名...>
decide() {
  local end="$1" want="$2" manifest="$3"; shift 3
  local have=""
  if printf '%s\n' "$ASSETS" | grep -qx "$manifest"; then
    have=$(gh release download "$LATEST" -p "$manifest" -O - 2>/dev/null | jq -r '.version // empty' || true)
  fi
  if [ "$have" != "$want" ]; then
    echo "${end}：本次 ${want}，Latest（${LATEST}）是 ${have:-无清单} ⇒ 构建" >&2
    echo build; return
  fi
  local f
  for f in "$@"; do
    if ! printf '%s\n' "$ASSETS" | grep -qx "$f"; then
      echo "${end}：版本号未变（${want}），但 Latest 缺 ${f} ⇒ 构建" >&2
      echo build; return
    fi
  done
  echo "${end}：版本号未变（${want}）⇒ 复用 ${LATEST} 的产物" >&2
  echo reuse
}

ANDROID=$(decide android "$ANDROID_VER" manifest-android.json "P-Pass_${ANDROID_VER}_android.apk")
MACOS=$(decide macos "$MACOS_VER" manifest-macos.json \
  "P-Pass_${MACOS_VER}_macos-arm64.dmg" "P-Pass_${MACOS_VER}_macos-arm64.app.tar.gz" "SHA256SUMS-macos-arm64")

if [ "$ANDROID" = reuse ] && [ "$MACOS" = reuse ]; then
  echo "::error::两端版本号都与 Latest（${LATEST}）相同——这次正式 tag 没有可发布的新版本。要发布哪一端，先在 release/versions.json 里涨它的号。"
  exit 1
fi

# 被复用的一端：Latest 之后改过会影响产物的构建脚本 ⇒ 提醒（这次不会生效）。
warn_tooling() {
  local end="$1"; shift
  local changed
  changed=$(git diff --name-only "$LATEST" HEAD -- "$@" 2>/dev/null || true)
  if [ -n "$changed" ]; then
    echo "::warning::${end} 本次复用 ${LATEST} 的产物，但它的构建脚本在那之后改过（$(echo "$changed" | tr '\n' ' ')）——这些改动要等 ${end} 下次涨号才会进安装包。"
  fi
}
[ "$ANDROID" = reuse ] && warn_tooling android tools/build-android-iroh-blobs-bridge.sh
[ "$MACOS" = reuse ] && warn_tooling macos tools/bundle-macos.sh tools/bundle-desktop-macos.sh tools/fetch-ffmpeg.sh

emit android "$ANDROID"
emit macos "$MACOS"
emit reuse_from "$LATEST"
