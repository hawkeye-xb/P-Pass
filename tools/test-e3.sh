#!/usr/bin/env bash
# tools/e3 自测（离线，不碰设备）：脚本语法、场景接口齐全、判定回放（fixtures 的 pass 必须过、fail 必须红）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E3="$ROOT/tools/e3"
fails=0
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

for f in "$E3"/run "$E3"/verify "$E3"/lock "$E3"/dev "$E3"/restore "$E3"/lib/*.sh "$E3"/scenarios/*/*.sh; do
  bash -n "$f" || bad "语法：$f"
done
for f in "$E3"/scenarios/*/*.sh; do
  grep -q '^DESC="' "$f" || bad "缺 DESC：$f"
  grep -q '^judge()' "$f" "$E3"/lib/android-*.sh 2>/dev/null || bad "缺 judge：$f"
  if grep -q '^COUNTER=on' "$f" && ! grep -q '^counter()' "$f"; then
    # 共享库里定义 counter 的（android-thumb.sh）也算
    grep -q 'source "$E3_LIB/android-thumb.sh"' "$f" || bad "COUNTER=on 却没有 counter：$f"
  fi
done
[ "$("$E3/run" list | wc -l | tr -d ' ')" -ge 8 ] || bad "run list 列不全"

# 判定回放：fixtures/<场景 id 的 / 换成 ->/{pass,fail}
for d in "$E3"/fixtures/*/; do
  id="$(basename "$d")"
  id="${id/-//}"
  "$E3/run" judge "$id" "$d/pass" >/dev/null || bad "${id}：pass fixture 没判过"
  "$E3/run" judge "$id" "$d/fail" >/dev/null && bad "${id}：fail fixture 没判红"
done

# #1311 数据快照：服务在跑不存；存 → 候选改库（新迁移、新文件）→ 恢复后库回到快照，照片原件不动
# 依赖 macOS 的 ditto；没有它（Windows/Linux）时跳过并说明原因（#1366）。
if ! command -v ditto >/dev/null 2>&1; then
  echo "SKIP: mac 数据快照存/恢复（本机没有 ditto，非 macOS）"
else
(
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  MAC_APP="$d/none.app" E3_MAC_DATA_DIR="$d/as" E3_STATE="$d/state"
  log() { :; }
  running=1
  svc_any_pid() { [ "$running" = 1 ] && echo 123; return 0; }
  # shellcheck source=e3/lib/mac-install.sh
  source "$E3/lib/mac-install.sh"
  mkdir -p "$d/as/libraries/x" "$d/lib/.ppf" "$d/lib/originals"
  printf 'data_dir = "%s"\n' "$d/lib" >"$d/as/config.toml"
  echo v13 >"$d/as/libraries/x/index.sqlite"
  echo id >"$d/lib/.ppf/library-id"
  echo a >"$d/lib/originals/a.jpg"
  mac_data_save "$d/snap" && { echo "服务在跑时存了快照"; exit 1; }
  running=0
  mac_data_save "$d/snap" || { echo "存快照失败"; exit 1; }
  echo v14 >"$d/as/libraries/x/index.sqlite"
  echo n >"$d/as/libraries/x/new-thumb"
  echo n >"$d/lib/.ppf/extra"
  echo b >"$d/lib/originals/b.jpg"
  mac_data_restore "$d/snap" || { echo "恢复失败"; exit 1; }
  [ "$(cat "$d/as/libraries/x/index.sqlite")" = v13 ] || { echo "库索引没回到快照"; exit 1; }
  [ ! -e "$d/as/libraries/x/new-thumb" ] && [ ! -e "$d/lib/.ppf/extra" ] || { echo "候选新写的文件残留"; exit 1; }
  [ -f "$d/lib/originals/b.jpg" ] || { echo "照片原件被动了"; exit 1; }
  [ "$(mac_library_dir "$d/as")" = "$d/lib" ] || { echo "库目录读错"; exit 1; }
  # 清成空白：要先有数据快照；清掉索引与 blob，留库标识与原件
  mac_data_blank && { echo "没有数据快照也清了"; exit 1; }
  mkdir -p "$E3_STATE/mac-snapshot/data"
  mac_data_blank || { echo "清空白失败"; exit 1; }
  [ ! -e "$d/as/libraries" ] && [ ! -e "$d/lib/.ppf/extra" ] || { echo "索引或 blob 没清掉"; exit 1; }
  [ -f "$d/lib/.ppf/library-id" ] && [ -f "$d/lib/originals/a.jpg" ] && [ -f "$d/as/config.toml" ] ||
    { echo "库标识、原件或 config.toml 被清了"; exit 1; }
) || bad "mac 数据快照存/恢复"
fi

# 设备锁：第二个持锁者要等第一个释放（/usr/bin/lockf 只有 macOS 有）
if [ "$(uname)" = Darwin ]; then
lockdir="$(mktemp -d)"
E3_STATE="$lockdir" "$E3/lock" ios sh -c 'sleep 2' &
sleep 0.5
t0=$SECONDS
E3_STATE="$lockdir" "$E3/lock" ios true 2>/dev/null
[ $((SECONDS - t0)) -ge 1 ] || bad "设备锁没有排队"
wait
rm -rf "$lockdir"
fi

# #1343：android 代码有改动时，ensure_base_apk 不许把候选包当基线。
# 用假仓库造 diff，直接调 source 出来的函数，不编 APK、不碰设备。
(
  d="$(mktemp -d)" || exit 1
  trap 'rm -rf "$d"' EXIT
  fake="$d/repo"
  mkdir -p "$fake/tools" "$fake/.github/workflows" "$fake/apps/android/app/src" \
    "$fake/apps/android/app/build/outputs/apk/debug"
  cp "$ROOT/tools/ci-paths.sh" "$fake/tools/ci-paths.sh"
  chmod +x "$fake/tools/ci-paths.sh"
  cat >"$fake/.github/workflows/ci-android.yml" <<'YML'
jobs:
  changes:
    steps:
      - with:
          paths: |
            apps/android/**
            tools/ci-paths.sh
YML
  printf 'candidate\n' >"$fake/apps/android/app/build/outputs/apk/debug/app-debug.apk"
  git -C "$fake" init -q
  git -C "$fake" add -A
  git -C "$fake" -c user.name=t -c user.email=t@t commit -q -m base
  base="$(git -C "$fake" rev-parse HEAD)"
  export E3_STATE="$d/state"
  # shellcheck source=../tools/e3/verify
  source "$E3/verify" || exit 1
  REPO_ROOT="$fake"
  cd "$fake" || exit 1 # lane_hit 里 ci-paths.sh 按当前目录取 git diff
  root="$d/root"
  mkdir -p "$root"
  build_apk() { return 1; } # 真去编基线就会失败：用来证明没走「拷候选包」分支

  # 1) android 有改动：必须走编基线分支。顶层新文件让「glob 被 shell 展开成子目录」的回归也红。
  printf 'x\n' >"$fake/apps/android/app/src/x.kt"
  printf 'y\n' >"$fake/apps/android/newfile.kt"
  git -C "$fake" add -A
  git -C "$fake" -c user.name=t -c user.email=t@t commit -q -m android
  if ensure_base_apk; then
    echo "android 有改动，ensure_base_apk 却成功返回（把候选包当基线了）"
    exit 1
  fi
  [ ! -f "$(base_apk_path)" ] || { echo "android 有改动，基线包却被写了出来"; exit 1; }

  # 2) 只有非 android 改动：同一份应用代码，允许直接拷候选包
  git -C "$fake" checkout -q -b docs-only "$base"
  printf 'note\n' >"$fake/docs.md"
  git -C "$fake" add -A
  git -C "$fake" -c user.name=t -c user.email=t@t commit -q -m docs
  E3_STATE="$d/state-docs"
  if ! ensure_base_apk; then
    echo "非 android 改动，ensure_base_apk 应直接拷候选包却失败了"
    exit 1
  fi
  [ -f "$(base_apk_path)" ] || { echo "非 android 改动，候选包没有拷成基线"; exit 1; }
) || bad "ensure_base_apk：android 改动判定"

# #1343 审查补充：MAC_GLOBS 数组里的通配符必须加引号。未加引号时，赋值那一刻 shell 会按
# 当前目录展开（在仓库根目录 crates/** 会变成一堆具体目录），通配语义和与目录无关性都丢了。
(
  cd "$ROOT" || exit 1
  E3_STATE="$(mktemp -d)" || exit 1
  export E3_STATE
  trap 'rm -rf "$E3_STATE"' EXIT
  # shellcheck source=../tools/e3/verify
  source "$E3/verify" || exit 1
  [ "${MAC_GLOBS[0]}" = 'crates/**' ] ||
    { printf 'MAC_GLOBS[0]=%s，期望字面量 crates/**\n' "${MAC_GLOBS[0]}"; exit 1; }
  [ "${#MAC_GLOBS[@]}" -eq 7 ] ||
    { printf 'MAC_GLOBS 有 %s 项，期望 7\n' "${#MAC_GLOBS[@]}"; exit 1; }
) || bad "MAC_GLOBS 通配符被 shell 按路径展开"

[ "$fails" -eq 0 ] && echo "ok: tools/e3 自测通过" || { echo "$fails 项失败"; exit 1; }
