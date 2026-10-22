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
#   - 两端都判「复用」且 iOS 也不构建：报错退出——没有新版本，这次正式 tag 没有可发布的东西。
#   - iOS（#348）：TestFlight 没有可复用的安装包，也不能重复上传同一构建号 ⇒ 只有 build / skip。
#     判据 = release/versions.json 的 ios 号与「上一个正式发布（Latest）那个 tag 里的 versions.json.ios」比：
#     相同 ⇒ skip；不同 / 上一版里没有 ios / 没有 Latest / Latest 就是本 tag ⇒ build。
#     （补跑 / 重复上传由 testflight-upload.sh 在 App Store Connect 侧查重，已在则幂等跳过。）
#   test tag（#852：test 通道镜像正式版的按端发布）：版本号就是 tag 名、每次都变，不能按
#   版本号判，改按「该端的输入自上一次 test 发布以来变没变」判。
#   - 基线 = test-channel 里该端分端清单的 version 对应的 tag（= 该端测试机上正装着的那一版；
#     正常就是上一个 test tag；上次该端构建失败时是更早那个——那段改动不会被漏掉）。
#   - 基线拿不到（清单不在 / 读不出 / tag 不存在 / 不是 HEAD 的祖先 / 就是本 tag）或 diff 失败：构建。
#   - 改动路径分类（反向 allowlist，同 tools/ci-needs-full-lane.sh：没列出的一律算所有端）：
#       docs/ cards/ .claude/ *.md                                  不影响产物
#       apps/android/、tools/build-android-iroh-blobs-bridge.sh      只算 Android
#       apps/desktop/src-tauri/tauri.windows.conf.json              只算 Windows
#       tools/bundle-macos.sh、tools/bundle-desktop-macos.sh、tools/daemon-helper-macos.sh、tools/fetch-ffmpeg.sh
#                                                                   只算 macOS
#       apps/desktop/（其余）                                       两个桌面端（macOS + Windows）
#       apps/ios/、tools/ios/、tools/build-ios-*                    只算 iOS（#887；#348 起有发版 lane：TestFlight）
#       apps/android/…/values{,-zh}/strings.xml                     Android + iOS（iOS 界面文案由它生成，gen-strings.py）
#       crates/、tools/testclient/、根 Cargo.toml / Cargo.lock       按 Cargo 依赖图归属到端（#1062，见下）
#       其余（assets/、release/、tools/、.github/、rust-toolchain.toml …） 所有端
#   - Rust 改动（#1062，tools/release/rust-impact.py）：cargo metadata（--no-deps，不联网）算出每端入口包
#     （Android transport[android-jni]、iOS transport[ios-ffi]、macOS daemon + 桌面壳、Windows daemon +
#     testclient + 桌面壳）传递依赖哪些 workspace crate，改动的 crate 只触发依赖它的端。根 Cargo.toml 只变
#     workspace 版本号 ⇒ 桌面两端；Cargo.lock 按变动的外部包反查依赖它的 crate。拿不准（cargo / python3
#     不可用、metadata 失败、crates/ 下的非成员路径、lock 对不上号）⇒ 所有端。
#   - assets/（含 assets/i18n/）仍算所有端：i18n 由 daemon（diag）、Android（逐字节捆绑副本）与
#     iOS（sync-i18n）三方各自打进产物，按需裁剪另行设计，在那之前不拆。
#   - 没改动的一端判 skip：不构建、也不复用（不复制任何产物），test-channel 里它的清单不动。
#   - Windows（2026-10-12 验收人：只改别的端时不陪跑 Windows）按同一规则判，基线是
#     test-channel/manifest-windows.json。正式 tag 不构建 Windows（windows=skip），手动 dispatch 不看这里。
#   - iOS（#348）同一套规则，基线是 test-channel/manifest-ios.json（上传 TestFlight 成功后由 finalize-ios 写入，
#     只有 version）。TestFlight 不能重复上传同一个构建号，所以 iOS 只有 build / skip，没有 reuse。
#   - 所有端都是 skip：报错退出——这次 test tag 没有可发布的东西。
#
# 输入：TAG；当前目录 = 检出的仓库（读 release/versions.json；test tag 要完整历史与 tag）；
#   gh 已登录（GH_TOKEN）。
# 输出（追加到 $GITHUB_OUTPUT，未设置时打印到 stdout）：
#   android=build|reuse|skip  macos=build|reuse|skip  windows=build|skip  ios=build|skip  reuse_from=<Latest tag 或空>
#   android_version=<号>  macos_version=<号>  ios_version=<号，versions.json 里没有 ios 时为空>
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
IOS_VER=$(jq -r '.ios // empty' release/versions.json)
emit android_version "$ANDROID_VER"
emit macos_version "$MACOS_VER"
emit ios_version "$IOS_VER"

if [[ "$TAG" == *-test.* ]]; then
  # test_base <清单名...>：test-channel 里该端清单的 version 对应的 tag（第一个读得到的为准）。
  test_base() {
    local m v
    for m in "$@"; do
      v=$(gh release download test-channel -p "$m" -O - 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)
      if [ -n "$v" ]; then echo "v${v#v}"; return; fi
    done
  }
  # #1062：Rust 依赖图只取一次（本次提交）。plan-builds job 用 RUSTUP_TOOLCHAIN=stable（release.yml）免装钉住的
  # 工具链——--no-deps 只读清单，不编译。取不到 ⇒ 不传 --meta，rust-impact.py 把 Rust 路径一律判 all。
  RUST_META_DIR=$(mktemp -d)
  trap 'rm -rf "$RUST_META_DIR"' EXIT
  RUST_META=()
  if cargo metadata --no-deps --format-version 1 --offline >"$RUST_META_DIR/ws.json" 2>"$RUST_META_DIR/err" \
    && { [ ! -f apps/desktop/src-tauri/Cargo.toml ] \
      || cargo metadata --no-deps --format-version 1 --offline --manifest-path apps/desktop/src-tauri/Cargo.toml \
        >"$RUST_META_DIR/shell.json" 2>>"$RUST_META_DIR/err"; }; then
    RUST_META=(--meta "$RUST_META_DIR/ws.json")
    [ -s "$RUST_META_DIR/shell.json" ] && RUST_META+=(--meta "$RUST_META_DIR/shell.json")
  else
    echo "::warning::cargo metadata 失败，Rust 改动无法按依赖图归属，一律算所有端：$(tr '\n' ' ' <"$RUST_META_DIR/err")"
  fi
  # 改动路径 → 影响哪些端（空格分隔）：android / macos / windows / desktop（两个桌面端）/ ios / all / none（分类见文件头）。
  classify() {
    case "$1" in
      docs/* | cards/* | .claude/* | *.md) echo none ;;
      # #348：iOS 界面文案由 Android strings.xml 生成（tools/ios/gen-strings.py）⇒ 同时影响两端。
      apps/android/app/src/main/res/values/strings.xml | apps/android/app/src/main/res/values-zh/strings.xml) echo android ios ;;
      apps/android/* | tools/build-android-iroh-blobs-bridge.sh) echo android ;;
      apps/desktop/src-tauri/tauri.windows.conf.json) echo windows ;;
      # #1121：正式更新公钥在这里，Android 构建期也读它（build.gradle.kts）⇒ 两端都受影响。
      apps/desktop/src-tauri/tauri.conf.json) echo desktop android ;;
      apps/desktop/src-tauri/tauri.macos.conf.json | apps/desktop/src-tauri/macos/*) echo macos ;;
      tools/bundle-macos.sh | tools/bundle-desktop-macos.sh | tools/daemon-helper-macos.sh | tools/fetch-ffmpeg.sh) echo macos ;;
      apps/desktop/*) echo desktop ;;
      # #887：iOS 工程与它专用的脚本不进 Android/macOS/Windows 的产物，只触发 iOS（#348 起有发版 lane）。
      apps/ios/* | tools/ios/* | tools/build-ios-*) echo ios ;;
      *) echo all ;;
    esac
  }
  # decide_test <端> <受哪些分类影响（空格分隔）> <清单名...>
  decide_test() {
    local end="$1" kinds="$2"; shift 2
    local base changed f k ks
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
    # --no-renames：移走的文件按原路径也算一次（否则只剩新路径，原 crate 的改动会被漏掉）。
    if ! changed=$(git diff --no-renames --name-only "$base" HEAD --); then
      echo "${end}：git diff ${base} HEAD 失败 ⇒ 构建" >&2; echo build; return
    fi
    # #1062：Rust 路径先交 rust-impact.py 按依赖图归属（每行「归属<TAB>路径」，- = 交回 classify）。
    if ! attributed=$(printf '%s\n' "$changed" | python3 -I tools/release/rust-impact.py --base "$base" ${RUST_META[@]+"${RUST_META[@]}"}); then
      echo "${end}：Rust 依赖归属失败 ⇒ 构建" >&2; echo build; return
    fi
    while IFS=$'\t' read -r ks f; do
      [ -n "$f" ] || continue
      [ "$ks" = - ] && ks=$(classify "$f")
      for k in $ks; do
        if [ "$k" = all ] || [[ " $kinds " == *" $k "* ]]; then
          echo "${end}：自 ${base} 起改了 ${f}（${k}）⇒ 构建" >&2; echo build; return
        fi
      done
    done <<<"$attributed"
    echo "${end}：自 ${base} 起没有影响该端的改动 ⇒ 不构建，test-channel 里该端清单不动" >&2
    echo skip
  }
  # 过渡期：#852 之前 test-channel 只有老格式 manifest.json，它就是 Android 的清单。
  ANDROID=$(decide_test android android manifest-android.json manifest.json)
  MACOS=$(decide_test macos "macos desktop" manifest-macos.json)
  WINDOWS=$(decide_test windows "windows desktop" manifest-windows.json)
  IOS=$(decide_test ios ios manifest-ios.json)
  if [ "$ANDROID" = skip ] && [ "$MACOS" = skip ] && [ "$WINDOWS" = skip ] && [ "$IOS" = skip ]; then
    echo "::error::test tag ${TAG}：各端自上一次 test 发布以来都没有影响产物的改动——这次没有可发布的东西。"
    exit 1
  fi
  emit android "$ANDROID"; emit macos "$MACOS"; emit windows "$WINDOWS"; emit ios "$IOS"; emit reuse_from ""
  exit 0
fi

# 正式 tag 不构建 Windows（是否正式发布 Windows 由验收人决定，#788）。
emit windows skip

# iOS（#348）：只有 build / skip。基线 = Latest 那个 tag 里的 release/versions.json.ios。
# 拿不到基线（没有 Latest / 就是本 tag / tag 不在仓库 / 那一版没有 ios 线）一律构建；本次没有 ios 号则不构建。
decide_ios() {
  local latest="$1" prev
  if [ -z "$IOS_VER" ]; then echo "ios：release/versions.json 里没有 ios 号 ⇒ 不构建" >&2; echo skip; return; fi
  if [ -z "$latest" ] || [ "$latest" = "$TAG" ]; then
    echo "ios：没有可比对的上一个正式发布（Latest=${latest:-无}）⇒ 构建" >&2; echo build; return
  fi
  if ! prev=$(git show "${latest}:release/versions.json" 2>/dev/null | jq -r '.ios // empty' 2>/dev/null) || [ -z "$prev" ]; then
    echo "ios：${latest} 里没有 ios 版本线 ⇒ 构建" >&2; echo build; return
  fi
  if [ "$prev" = "$IOS_VER" ]; then
    echo "ios：版本号未变（${IOS_VER}，同 ${latest}）⇒ 不构建（TestFlight 不能重复上传同一构建号）" >&2; echo skip; return
  fi
  echo "ios：本次 ${IOS_VER}，${latest} 是 ${prev} ⇒ 构建" >&2; echo build
}

LATEST=$(gh release view --json tagName -q .tagName 2>/dev/null || true)
if [ -z "$LATEST" ] || [ "$LATEST" = "$TAG" ]; then
  echo "没有可复用的 Latest（Latest=${LATEST:-无}）：各端都构建"
  emit android build; emit macos build; emit ios "$(decide_ios "$LATEST")"; emit reuse_from ""
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

IOS=$(decide_ios "$LATEST")

if [ "$ANDROID" = reuse ] && [ "$MACOS" = reuse ] && [ "$IOS" = skip ]; then
  echo "::error::各端版本号都与 Latest（${LATEST}）相同——这次正式 tag 没有可发布的新版本。要发布哪一端，先在 release/versions.json 里涨它的号。"
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
# #894：安卓原生库（libtransport.so）的输入也算——与 tools/check-version-bump.sh 的 ANDROID_INPUTS 同口径。
[ "$ANDROID" = reuse ] && warn_tooling android tools/build-android-iroh-blobs-bridge.sh \
  crates/transport Cargo.toml Cargo.lock rust-toolchain.toml
[ "$MACOS" = reuse ] && warn_tooling macos tools/bundle-macos.sh tools/bundle-desktop-macos.sh tools/daemon-helper-macos.sh tools/fetch-ffmpeg.sh

emit android "$ANDROID"
emit macos "$MACOS"
emit ios "$IOS"
emit reuse_from "$LATEST"
