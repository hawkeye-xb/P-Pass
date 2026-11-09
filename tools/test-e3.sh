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
  # fail、fail-<原因>…：每个反例只让一条判据出错，删掉或放宽那条判据回放就会红
  for f in "$d"/fail "$d"/fail-*; do
    [ -d "$f" ] || continue
    "$E3/run" judge "$id" "$f" >/dev/null && bad "${id}：$(basename "$f") fixture 没判红"
  done
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
  # 改数据的函数要求持 mac 锁（#1449，mac_need_lock 在 mac.sh；这里不 source 它）：只动临时目录，视作持锁
  mac_need_lock() { :; }
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

# 等后台持锁者真的拿到锁（不靠固定 sleep：机器忙时持锁者可能还没起来，判定就成了碰运气）
wait_held() { # wait_held <锁文件>
  local i
  for i in $(seq 1 100); do
    [ -f "$1" ] && ! /usr/bin/lockf -k -t 0 "$1" true 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# 设备锁：第二个持锁者要等第一个释放（/usr/bin/lockf 只有 macOS 有）
if [ "$(uname)" = Darwin ]; then
lockdir="$(mktemp -d)"
E3_STATE="$lockdir" "$E3/lock" ios sh -c 'sleep 2' &
wait_held "$lockdir/lock-ios" || bad "持锁者 10 秒内没拿到锁"
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
  git -C "$fake" init --template= -q
  git -C "$fake" add -A
  git -C "$fake" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m base
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
  git -C "$fake" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m android
  if ensure_base_apk; then
    echo "android 有改动，ensure_base_apk 却成功返回（把候选包当基线了）"
    exit 1
  fi
  [ ! -f "$(base_apk_path)" ] || { echo "android 有改动，基线包却被写了出来"; exit 1; }

  # 2) 只有非 android 改动：同一份应用代码，允许直接拷候选包
  git -C "$fake" checkout -q -b docs-only "$base"
  printf 'note\n' >"$fake/docs.md"
  git -C "$fake" add -A
  git -C "$fake" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m docs
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

# #1375 just dev 手机：设备被占就拒绝（--no-wait），不排队；反证：释放后同一条命令成功
if [ "$(uname)" = Darwin ]; then
  lockdir="$(mktemp -d)"
  E3_STATE="$lockdir" "$E3/lock" android sh -c 'sleep 3' &
  holder=$!
  wait_held "$lockdir/lock-android" || bad "持锁者 10 秒内没拿到锁"
  t0=$SECONDS
  E3_STATE="$lockdir" "$E3/lock" --no-wait android true 2>"$lockdir/err"
  rc=$?
  [ "$rc" = 75 ] || bad "设备被占时 --no-wait 没拒绝（退出码 ${rc}）"
  [ $((SECONDS - t0)) -lt 2 ] || bad "设备被占时 --no-wait 排队了"
  grep -q '正被别的会话占用（pid ' "$lockdir/err" || bad "拒绝时没说谁占着：$(cat "$lockdir/err")"
  wait "$holder"
  E3_STATE="$lockdir" "$E3/lock" --no-wait android true || bad "锁释放后 --no-wait 仍被拒绝"
  rm -rf "$lockdir"
fi

# #1449 .who 只代表活着的持有者：持有期间 status 报占用；命令退出后不留记录、退出码原样透传；
# 记录指向已退出的进程（kill -9 收不了尾、或人为造的）→ status 不报占用，说明是残留并清掉。
if [ "$(uname)" = Darwin ]; then
  (
    d="$(mktemp -d)" || exit 1
    export E3_STATE="$d"
    trap 'kill "$(cat "$d/sleeper" 2>/dev/null)" 2>/dev/null; rm -rf "$d"' EXIT
    line() { "$E3/lock" status | grep "^$1 "; }
    # 持有期间 status 报占用（也是下面「空闲」判定的反证：同一个 status，只差有没有活着的持有者）
    "$E3/lock" ios sh -c 'sleep 3' &
    holder=$!
    wait_held "$d/lock-ios" || { echo "持锁者 10 秒内没拿到锁"; exit 1; }
    st="$(line ios)"
    printf '%s' "$st" | grep -q '正被占用（pid ' || { echo "持有期间 status 没报占用：$st"; exit 1; }
    wait "$holder"
    [ ! -e "$d/lock-ios.who" ] || { echo "持有命令退出后 .who 还在：$(cat "$d/lock-ios.who")"; exit 1; }
    st="$(line ios)"
    printf '%s' "$st" | grep -q '空闲$' || { echo "持有命令退出后 status 不是空闲：$st"; exit 1; }
    "$E3/lock" ios sh -c 'exit 3'
    rc=$?
    [ "$rc" = 3 ] || { echo "被包命令的退出码没透传（得到 ${rc}）"; exit 1; }
    [ ! -e "$d/lock-ios.who" ] || { echo "命令失败退出后 .who 还在"; exit 1; }
    # 人为造一条指向不存在进程的记录
    sh -c 'exit 0' &
    dead=$!
    wait "$dead"
    echo "pid $dead 00:00:00 /nowhere" >"$d/lock-mac.who"
    st="$(line mac)"
    printf '%s' "$st" | grep -q "空闲（残留记录指向已退出的进程 ${dead}）" || { echo "死 pid 的记录 status 没认出残留：$st"; exit 1; }
    [ ! -e "$d/lock-mac.who" ] || { echo "status 没清掉残留记录"; exit 1; }
    # kill -9 持锁的 lockf：收不了尾，留下的记录由 status 认出并清掉
    "$E3/lock" android sh -c 'echo $$ >"$0"; exec sleep 30' "$d/sleeper" &
    holder=$!
    wait_held "$d/lock-android" || { echo "持锁者 10 秒内没拿到锁"; exit 1; }
    lk_pid="$(sed -n 's/^pid \([0-9]*\) .*/\1/p' "$d/lock-android.who")"
    [ "$lk_pid" = "$holder" ] || { echo ".who 记的不是持锁的 lockf（${lk_pid} ≠ ${holder}）"; exit 1; }
    kill -9 "$holder"
    wait "$holder" 2>/dev/null
    st="$(line android)"
    printf '%s' "$st" | grep -q "空闲（残留记录指向已退出的进程 ${holder}）" || { echo "kill -9 后 status 不对：$st"; exit 1; }
    [ ! -e "$d/lock-android.who" ] || { echo "kill -9 后 status 没清掉残留"; exit 1; }
    "$E3/lock" --no-wait android true || { echo "kill -9 后取锁仍被拒"; exit 1; }
    exit 0
  ) || bad "设备锁 .who 只代表活着的持有者（#1449）"
fi

# #1449 人工验收：owner 替人拿锁（hold-for-human，一次多台、跨命令持有）→ agent 取锁排队、--no-wait 退出 75；
# release-human 后排队的接着跑；持锁进程被 kill 后锁自动释放、status 不报占用。
if [ "$(uname)" = Darwin ]; then
  (
    d="$(mktemp -d)" || exit 1
    export E3_STATE="$d"
    trap '"$E3/lock" release-human mac ios >/dev/null 2>&1; rm -rf "$d"' EXIT
    line() { "$E3/lock" status | grep "^$1 "; }
    # 反证：没人工持锁时，同一条取锁命令立刻跑
    "$E3/lock" mac touch "$d/ran0" && [ -f "$d/ran0" ] || { echo "没人持锁时取锁的命令没跑"; exit 1; }
    "$E3/lock" hold-for-human mac ios >"$d/hold.out" 2>&1 || { echo "hold-for-human 失败：$(cat "$d/hold.out")"; exit 1; }
    st="$(line mac)"
    printf '%s' "$st" | grep -q '人工验收中（自 ' || { echo "人工持锁时 status 没显示人工验收中：$st"; exit 1; }
    st="$(line ios)"
    printf '%s' "$st" | grep -q '人工验收中（自 ' || { echo "一次拿两台，ios 没拿到：$st"; exit 1; }
    # 跨命令持有：hold-for-human 已返回，锁仍在
    "$E3/lock" --no-wait mac true 2>"$d/err"
    rc=$?
    [ "$rc" = 75 ] || { echo "人工持锁时 --no-wait 没退出 75（${rc}）"; exit 1; }
    grep -q '人工验收中' "$d/err" || { echo "--no-wait 拒绝时没说人工验收中：$(cat "$d/err")"; exit 1; }
    # 排队：取锁的命令在人工持锁期间不跑
    "$E3/lock" mac touch "$d/ran1" 2>"$d/queue.err" &
    q=$!
    sleep 3
    [ ! -e "$d/ran1" ] || { echo "人工持锁期间别的命令没排队就跑了"; exit 1; }
    kill -0 "$q" 2>/dev/null || { echo "排队的命令没在等，直接退出了"; exit 1; }
    grep -q '排队等待' "$d/queue.err" || { echo "排队时没说谁在用：$(cat "$d/queue.err")"; exit 1; }
    "$E3/lock" release-human mac >/dev/null || { echo "release-human mac 失败"; exit 1; }
    wait "$q" || { echo "release 后排队的命令失败"; exit 1; }
    [ -f "$d/ran1" ] || { echo "release 后排队的命令没跑"; exit 1; }
    st="$(line mac)"
    printf '%s' "$st" | grep -q '；空闲$' || { echo "release 后 mac 不是空闲：$st"; exit 1; }
    # 持锁进程意外死掉（kill -9 持锁的 lockf）：锁自动释放，status 不报占用
    hp="$(sed -n 's/^pid \([0-9]*\) .*/\1/p' "$d/lock-ios.who")"
    [ -n "$hp" ] && kill -9 "$hp"
    for _ in $(seq 1 50); do line ios | grep -q '空闲' && break; sleep 0.1; done
    st="$(line ios)"
    printf '%s' "$st" | grep -q '空闲' || { echo "人工持锁进程被 kill 后 status 仍报占用：$st"; exit 1; }
    "$E3/lock" --no-wait ios true || { echo "人工持锁进程被 kill 后取锁仍被拒"; exit 1; }
    sleep 1.5 # 持锁内容每秒看一次 lockf 还在不在：被 kill 后自己也退出，不留后台进程
    ! pgrep -f "$d/lock-ios.human" >/dev/null || { echo "持锁进程被 kill 后后台进程没退出"; exit 1; }
    exit 0
  ) || bad "人工验收锁 hold-for-human / release-human（#1449）"
fi

# #1449 改本机 P-Pass（正式版也算 mac 设备）的步骤必须在 mac 锁里：不持锁就拒绝、不碰 App；
# 反证：持锁（E3_LOCKED_MAC=1，lock 进锁时设的）同一调用照常替换。装包要停服务、等就绪的步骤用桩代替。
(
  d="$(mktemp -d)" || exit 1
  trap 'rm -rf "$d"' EXIT
  E3_MAC_APP="$d/Applications/P-Pass.app" E3_STATE="$d/state" E3_MAC_DATA_DIR="$d/as"
  export E3_MAC_APP E3_STATE E3_MAC_DATA_DIR
  log() { echo "$*" >>"$d/log"; }
  # shellcheck source=e3/lib/mac.sh
  source "$E3/lib/mac.sh"
  # shellcheck source=e3/lib/mac-install.sh
  source "$E3/lib/mac-install.sh"
  mkdir -p "$MAC_APP" "$d/cand.app" "$E3_STATE"
  echo old >"$MAC_APP/v"
  echo new >"$d/cand.app/v"
  # 数据守卫的前置条件都备齐（有数据快照、恢复源完整、服务没跑），没持锁是唯一会拦下它们的原因：
  # 否则删掉 mac_need_lock，函数也会因为别的前置条件返回 1，这条照样绿（CI 评审 #1456 指出）。
  mkdir -p "$E3_STATE/mac-snapshot/data" "$MAC_DATA_DIR/libraries" "$d/snap/appsupport"
  echo cur >"$MAC_DATA_DIR/config.toml"
  echo idx >"$MAC_DATA_DIR/libraries/index"
  echo snap >"$d/snap/appsupport/config.toml"
  : >"$d/snap/library-dir.txt"
  launchctl() { echo "launchctl $*" >>"$d/touched"; }
  osascript() { echo "osascript $*" >>"$d/touched"; }
  pkill() { echo "pkill $*" >>"$d/touched"; }
  ditto() { cp -R "$1" "$2"; } # 测的是锁守卫，不是 ditto：非 macOS 上也能跑
  mac_shell_running() { return 1; }
  svc_loaded() { return 1; }
  svc_any_pid() { :; }
  log_mark() { echo 0; }
  mac_wait_ready() { return 0; }
  unset E3_LOCKED_MAC
  for f in mac_install_app svc_stop svc_start mac_quit_shell mac_data_blank mac_data_restore; do
    case "$f" in
      mac_install_app) "$f" "$d/cand.app" ;;
      mac_data_restore) "$f" "$d/snap" ;;
      *) "$f" ;;
    esac && { echo "没持锁时 $f 照样执行了"; exit 1; }
    grep -q "拒绝 ${f}：没持 mac 设备锁" "$d/log" || { echo "没持锁时 $f 不是被锁守卫拦下的：$(tail -2 "$d/log")"; exit 1; }
  done
  [ "$(cat "$MAC_APP/v")" = old ] || { echo "没持锁时 App 被替换了"; exit 1; }
  [ -f "$MAC_DATA_DIR/libraries/index" ] || { echo "没持锁时 mac_data_blank 清了数据"; exit 1; }
  [ "$(cat "$MAC_DATA_DIR/config.toml")" = cur ] || { echo "没持锁时 mac_data_restore 覆盖了数据"; exit 1; }
  [ ! -e "$d/touched" ] || { echo "没持锁时碰了服务或外壳：$(cat "$d/touched")"; exit 1; }
  grep -q '没持 mac 设备锁' "$d/log" || { echo "拒绝时没说原因"; exit 1; }
  export E3_LOCKED_MAC=1
  mac_install_app "$d/cand.app" || { echo "持锁时装包失败：$(tail -3 "$d/log")"; exit 1; }
  [ "$(cat "$MAC_APP/v")" = new ] || { echo "持锁时 App 没被替换（反证不成立）"; exit 1; }
  mac_data_restore "$d/snap" || { echo "持锁时恢复数据失败：$(tail -3 "$d/log")"; exit 1; }
  [ "$(cat "$MAC_DATA_DIR/config.toml")" = snap ] || { echo "持锁时 mac_data_restore 没恢复（反证不成立）"; exit 1; }
  # 恢复数据那步删了 libraries/（快照里没有它），重建后再清，清空断言才有区分力
  mkdir -p "$MAC_DATA_DIR/libraries"
  echo idx >"$MAC_DATA_DIR/libraries/index"
  [ -f "$MAC_DATA_DIR/libraries/index" ] || { echo "造数据失败，反证不成立"; exit 1; }
  mac_data_blank || { echo "持锁时清空白失败：$(tail -3 "$d/log")"; exit 1; }
  [ ! -e "$MAC_DATA_DIR/libraries" ] || { echo "持锁时 mac_data_blank 没清（反证不成立）"; exit 1; }
  exit 0
) || bad "改本机 P-Pass 的步骤必须持 mac 锁（#1449）"
# 调用这些函数的入口都先取 mac 锁：场景经 run（cmd_run 先 exec lock）、dev mac、restore mac
grep -q 'exec "$E3_ROOT/lock" "$dev"' "$E3/run" &&
  grep -q 'exec "$E3_ROOT/lock" mac "$0" mac --install-only' "$E3/dev" &&
  grep -q 'exec "$E3_ROOT/lock" mac "$0"' "$E3/restore" || bad "run / dev mac / restore mac 不再先取 mac 锁"
for f in $(grep -rlE 'mac_install_app|mac_restore_(snapshot|tag)|svc_(stop|start)|mac_quit_shell|mac_data_(blank|restore)' "$E3" | grep -v '/lib/'); do
  case "$f" in "$E3"/scenarios/mac/* | "$E3"/dev | "$E3"/restore) ;; *) bad "${f#"$ROOT"/} 动本机 P-Pass，但不在已知持锁的入口里" ;; esac
done

# #1375 共享编译缓存：justfile 从当前目录往上读到 .env.ppass-dev；没有这个文件（CI）时不设 CARGO_TARGET_DIR
if command -v just >/dev/null 2>&1; then
  (
    d="$(cd -P "$(mktemp -d)" && pwd)" || exit 1
    trap 'rm -rf "$d"' EXIT
    mkdir -p "$d/main/sub"
    git -C "$d/main" init --template= -q
    unset CARGO_TARGET_DIR PPASS_DEV_CACHE_PARENT
    # shellcheck source=e3/lib/dev-cache.sh
    source "$E3/lib/dev-cache.sh"
    got="$(just --justfile "$ROOT/justfile" --working-directory "$d/main/sub" --command printenv CARGO_TARGET_DIR 2>/dev/null)"
    [ -z "$got" ] || { echo "没有配置文件却设了 CARGO_TARGET_DIR=$got"; exit 1; }
    f="$(dev_cache_init "$d/main/sub")" || { echo "dev_cache_init 失败"; exit 1; }
    [ "$f" = "$d/.env.ppass-dev" ] || { echo "配置不在主副本旁：$f"; exit 1; }
    got="$(just --justfile "$ROOT/justfile" --working-directory "$d/main/sub" --command printenv CARGO_TARGET_DIR)"
    [ "$got" = "$d/P-Pass-cache/cargo-target" ] || { echo "just 没读到共享 CARGO_TARGET_DIR（得到 ${got:-空}）"; exit 1; }
    got="$(CARGO_TARGET_DIR=/x just --justfile "$ROOT/justfile" --working-directory "$d/main/sub" --command printenv CARGO_TARGET_DIR)"
    [ "$got" = /x ] || { echo "环境里已设的 CARGO_TARGET_DIR 被配置覆盖了（得到 ${got}）"; exit 1; }
    echo 'CARGO_TARGET_DIR=/changed' >"$f"
    dev_cache_init "$d/main" >/dev/null
    grep -qx 'CARGO_TARGET_DIR=/changed' "$f" || { echo "dev_cache_init 覆盖了人改过的配置"; exit 1; }
    dev_cache_covers "$d/main-wt/1-x" || { echo "主副本旁的卡目录没认出被覆盖"; exit 1; }
    dev_cache_covers "$(mktemp -d)" && { echo "无关目录却认成被覆盖"; exit 1; }
    exit 0
  ) || bad "共享编译缓存配置"
fi

# #1375 just dev android：debug 包被 build.gradle.kts 改了名（P-Pass_<版本>_android-debug.apk），按目录取最新的
(
  d="$(mktemp -d)" || exit 1
  trap 'rm -rf "$d"' EXIT
  REPO_ROOT="$d"
  # shellcheck source=e3/lib/dev-phone.sh
  source "$E3/lib/dev-phone.sh"
  out="$d/apps/android/app/build/outputs/apk/debug"
  mkdir -p "$out"
  [ -z "$(dev_android_apk)" ] || { echo "没有包时却返回了路径"; exit 1; }
  touch -t 202601010000 "$out/P-Pass_0.10.1_android-debug.apk"
  touch "$out/P-Pass_0.10.2_android-debug.apk"
  [ "$(dev_android_apk)" = "$out/P-Pass_0.10.2_android-debug.apk" ] || { echo "没取到最新的改名包：$(dev_android_apk)"; exit 1; }
) || bad "just dev android 找改名后的 debug 包"
# #1378 设备归属：有主人的设备，别人取不到锁（不排队、退出 75、说出主人）；主人自己、release 之后都能取
if [ "$(uname)" = Darwin ]; then
  (
    d="$(mktemp -d)" || exit 1
    trap 'rm -rf "$d"' EXIT
    export E3_STATE="$d"
    unset PPASS_DEVICE_OWNER
    "$E3/lock" claim android 回归会话 >/dev/null || { echo "claim 失败"; exit 1; }
    "$E3/lock" android true 2>"$d/err"
    rc=$?
    [ "$rc" = 75 ] || { echo "设备有主人时别人取锁没被拒（退出码 ${rc}）"; exit 1; }
    grep -q '现在归 回归会话' "$d/err" || { echo "拒绝时没说主人：$(cat "$d/err")"; exit 1; }
    PPASS_DEVICE_OWNER=回归会话 "$E3/lock" android true || { echo "主人自己取锁被拒"; exit 1; }
    "$E3/lock" claim android 别的会话 2>/dev/null && { echo "有主人时别人 claim 成功了"; exit 1; }
    st="$("$E3/lock" status)" # 先存再判：grep -q 提前退出会让 pipefail 把管道判成失败
    printf '%s\n' "$st" | grep -q '^android  归 回归会话' || { echo "status 没列出主人：${st}"; exit 1; }
    "$E3/lock" release android >/dev/null
    "$E3/lock" android true || { echo "release 后取锁仍被拒"; exit 1; }
    st="$("$E3/lock" status)"
    printf '%s\n' "$st" | grep -q '^android  无主人；空闲' || { echo "release 后 status 不对：${st}"; exit 1; }
    exit 0
  ) || bad "设备归属（claim / release / status）"
fi

# #1511 mac/upgrade 的上一版：base_tag 只取已发布正式版（列表首项是 Draft 也跳过）；装的版本号对正式批次 tag
# 取该 tag 上 release/versions.json 的 desktop，test tag 与批次制之前的 tag 取 tag 名；读不到不猜。
# 假 gh 只在带齐 --exclude-drafts --exclude-pre-releases 时去掉 Draft；临时 git 仓库造 tag，不依赖本检出有没有 tag。
(
  d="$(mktemp -d)" || exit 1
  trap 'rm -rf "$d"' EXIT
  mkdir -p "$d/bin"
  cat >"$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" --exclude-drafts "*--exclude-pre-releases" "*) printf 'v2026.10.7\nv2026.10.6\n' ;;
  *) printf 'v2026.11.1\nv0.11.0-test.4\nv2026.10.7\n' ;;
esac
STUB
  chmod +x "$d/bin/gh"
  PATH="$d/bin:$PATH"
  log() { echo "$*" >>"$d/log"; }
  E3_LIB="$E3/lib" MAC_APP="$d/none.app"
  unset E3_MAC_BASE_TAG
  # shellcheck source=e3/scenarios/mac/upgrade.sh
  source "$E3/scenarios/mac/upgrade.sh"
  [ "$(base_tag)" = v2026.10.7 ] || { echo "列表首项是 Draft 时 base_tag 取成了 $(base_tag)"; exit 1; }
  [ "$(E3_MAC_BASE_TAG=v0.10.1 base_tag)" = v0.10.1 ] || { echo "E3_MAC_BASE_TAG 覆盖不生效"; exit 1; }

  export E3_TAG_REPO="$d/repo"
  git init --template= -q "$E3_TAG_REPO"
  mkdir -p "$E3_TAG_REPO/release"
  printf '{\n  "desktop": "0.10.1",\n  "android": "0.10.2"\n}\n' >"$E3_TAG_REPO/release/versions.json"
  git -C "$E3_TAG_REPO" add release/versions.json
  git -C "$E3_TAG_REPO" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -qm v
  git -C "$E3_TAG_REPO" tag v2026.10.7
  [ "$(mac_tag_version v2026.10.7)" = 0.10.1 ] || { echo "正式 tag 的版本没取 versions.json 的 desktop：$(mac_tag_version v2026.10.7)"; exit 1; }
  [ "$(mac_tag_version v0.11.0-test.4)" = 0.11.0-test.4 ] || { echo "test tag 的版本不是 tag 名"; exit 1; }
  [ "$(mac_tag_version v2026.10.7-test.1)" = 2026.10.7-test.1 ] || { echo "批次号前缀的 test tag 的版本不是 tag 名"; exit 1; }
  [ "$(mac_tag_version v0.10.1)" = 0.10.1 ] || { echo "批次制之前的 tag 的版本不是 tag 名"; exit 1; }
  mac_tag_version v2026.11.9 >/dev/null && { echo "本机没有的正式 tag 没判失败"; exit 1; }
  grep -q 'v2026.11.9' "$d/log" || { echo "取不到 tag 时没说明原因"; exit 1; }
  exit 0
) || bad "mac/upgrade 上一版 tag 与版本号（#1511）"

# #1378 模拟器用完即关：只关「要用的那台」且是本次运行期间才开机的；别的会话持着模拟器锁时不关。
# 用假 xcrun（读 $FAKE_SIM 目录），不碰真模拟器。
(
  d="$(mktemp -d)" || exit 1
  trap '[ -z "${holder:-}" ] || kill "$holder" 2>/dev/null; rm -rf "$d"' EXIT
  export FAKE_SIM="$d" TMPDIR="$d/tmp"
  mkdir -p "$d/bin" "$TMPDIR"
  cat >"$d/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "simctl list runtimes available -j") echo '{"runtimes":[{"platform":"iOS","isAvailable":true,"version":"26.4","identifier":"rt"}]}' ;;
  "simctl list devices available -j") echo '{"devices":{"rt":[{"name":"iPhone 17","udid":"TARGET"}]}}' ;;
  "simctl list devices booted -j") cat "$FAKE_SIM/booted.json" ;;
  "simctl shutdown "*) echo "$3" >>"$FAKE_SIM/shutdown" ;;
  *) echo "fake xcrun: unsupported $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$d/bin/xcrun"
  export PATH="$d/bin:$PATH"
  sim="$ROOT/tools/ios/sim.sh"
  booted() { # booted <udid:分钟前开机>...
    local items="" u m t
    for a in "$@"; do
      u="${a%%:*}" m="${a##*:}"
      t="$(python3 -I -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$m")"
      items="${items:+$items,}{\"name\":\"iPhone 17\",\"udid\":\"$u\",\"lastBootedAt\":\"$t\"}"
    done
    printf '{"devices":{"rt":[%s]}}' "$items" >"$d/booted.json"
  }
  booted
  before="$(bash "$sim" booted)"
  booted TARGET:1 OTHER:1
  bash "$sim" shutdown-new "$before" 2>/dev/null
  [ "$(cat "$d/shutdown" 2>/dev/null)" = TARGET ] || { echo "本次开的那台没关，或关了别的：$(cat "$d/shutdown" 2>/dev/null)"; exit 1; }
  rm -f "$d/shutdown"
  before="$(bash "$sim" booted)"
  bash "$sim" shutdown-new "$before" 2>/dev/null
  [ ! -e "$d/shutdown" ] || { echo "开跑前就开着的模拟器被关了"; exit 1; }
  booted
  before="$(bash "$sim" booted)"
  booted TARGET:1
  mkdir -p "$TMPDIR/ppass-ios-sim.lock"
  sleep 30 &
  holder=$!
  echo "$holder" >"$TMPDIR/ppass-ios-sim.lock/pid"
  bash "$sim" shutdown-new "$before" 2>/dev/null
  [ ! -e "$d/shutdown" ] || { echo "别的会话持着模拟器锁时仍关了模拟器"; exit 1; }
  [ -z "$(bash "$sim" idle 10)" ] || { echo "有人持锁时仍报闲置"; exit 1; }
  kill "$holder"
  wait "$holder" 2>/dev/null
  booted TARGET:25 OTHER:3
  idle="$(bash "$sim" idle 10)"
  printf '%s' "$idle" | grep -q 'TARGET' && ! printf '%s' "$idle" | grep -q 'OTHER' ||
    { echo "闲置判定不对（25 分钟的该报、3 分钟的不该报）：$idle"; exit 1; }
  [ "$(bash "$sim" lang-args en)" = "-testLanguage en -testRegion US" ] &&
    [ "$(bash "$sim" lang-args zh)" = "-testLanguage zh-Hans -testRegion CN" ] || { echo "测试语言参数不对"; exit 1; }
  bash "$sim" lang-args fr 2>/dev/null && { echo "不认识的语言没报错"; exit 1; }
  exit 0
) || bad "模拟器用完即关 / 闲置 / 测试语言"

[ "$fails" -eq 0 ] && echo "ok: tools/e3 自测通过" || { echo "$fails 项失败"; exit 1; }
