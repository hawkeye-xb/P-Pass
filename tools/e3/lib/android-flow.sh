# Android 常用流程：装包、与配对桩配对、开始备份。依赖 adb.sh、eph.sh。
# shellcheck shell=bash

# 候选包 / 基线包（上一版）。debug 包才有 run-as；debug 与 release 签名不同，不能互相覆盖安装。
cand_apk() {
  if [ -n "${E3_ANDROID_APK:-}" ]; then echo "$E3_ANDROID_APK"; return; fi
  ls -t "$REPO_ROOT"/apps/android/app/build/outputs/apk/debug/*.apk 2>/dev/null | head -1
}
base_apk() { echo "${E3_ANDROID_BASE_APK:-$E3_STATE/base/$(base_sha)/app-debug.apk}"; }
base_sha() { git -C "$REPO_ROOT" rev-parse --short "$(git -C "$REPO_ROOT" merge-base HEAD origin/main)"; }

# install_fresh <apk>：卸掉现有的再装（签名不同或要从零开始时）
install_fresh() {
  A uninstall "$PKG" >/dev/null 2>&1
  A install "$1" >/dev/null || die "安装失败：$1"
}

# pair_enter_code <证据目录>：App 停在欢迎页时，手动输入配对串 → 桩 IPC 批准。只配对，配对之后的页面不碰。
pair_enter_code() {
  local ev="$1" qr code node xy
  # 只认前缀：smoke-upgrade 在 main 的基线包上配对，基线包还是旧文案（11-04 前是「扫码连接家里的电脑」「手动输入配对码」）。
  wait_text "扫码连接" 30 || { ui_dump "$ev/pair-no-welcome.xml"; return 1; }
  tap_text "无法扫码？手动" || return 1
  wait_text "输入配对码" 15 || return 1
  qr=$(eph_qr) || return 1
  xy=$(python3 -I "$E3_LIB/ui.py" class "$UI_XML" EditText) || { log "找不到配对码输入框"; return 1; }
  fg_guard && tap_xy "$xy" || return 1
  fg_guard && A shell "input text '$qr'" || return 1
  sleep 0.5
  ui_dump && ui_has "ppf://pair?node=" || { log "配对串没输进去"; return 1; }
  tap_text "连接" || return 1
  wait_text "验证码" 60 || { ui_dump "$ev/pair-no-code.xml"; return 1; }
  ui_dump "$ev/pair-code.xml"
  code=$(python3 -I "$E3_LIB/ui.py" grep "$UI_XML" '^[0-9]{3} ?[0-9]{3}$' | tr -d ' ')
  node=
  for _ in $(seq 1 30); do
    node=$(eph_ipc pairing.pending | python3 -I -c 'import json,sys; p=json.load(sys.stdin)["result"]["pending"]; print(p[-1]["node_id"] if p else "")')
    [ -n "$node" ] && break
    sleep 1
  done
  [ -n "$node" ] && [ -n "$code" ] || { log "没等到配对请求（node=$node code=${code}）"; return 1; }
  eph_ipc pairing.confirm "{\"accept\":true,\"node_id\":\"$node\",\"code\":\"$code\"}" >"$ev/pair-confirm.json" || return 1
  echo "$node" >"$E3_STATE/android-node"
}

# pair_with_stub <证据目录>：清数据 → 配对 →（#1321 决定页「选择备份范围」）→ 系统照片权限框「全部允许」→
# 范围只勾专用测试相册 →「开始备份」→ 读回存下的范围核对。调用前专用相册里要已有图（album_seed 或场景自己推）。
# 只在 P-Pass 在前台时点。成功返回 0。
pair_with_stub() {
  local ev="$1" end
  app_stop
  A shell pm clear "$PKG" >/dev/null
  app_start
  pair_enter_code "$ev" || return 1
  # #1321 起配对后先进决定页（候选包）；上一版包（#1272 起）配对后直接进照片页，从「开启自动备份」进。
  if wait_text "选择要自动备份的照片" 15; then tap_text "选择备份范围" || return 1
  elif ui_has "开启自动备份"; then tap_text "开启自动备份" || return 1; fi
  # 系统照片权限框 → 全部允许；之后「开始备份」
  end=$((SECONDS + 60))
  while [ $SECONDS -lt $end ]; do
    fg | grep -q permissioncontroller && break
    sleep 1
  done
  tap_text "全部允许" || tap_text "Allow all" || { log "没等到系统照片权限框"; return 1; }
  sleep 3
  # #1412：范围只勾专用测试相册。首次选范围页按钮是「开始备份」、默认勾相机相册（点一下取消）；
  # 上一版的选范围页按钮是「保存」、默认不勾。两种都点上测试相册，存下之后读回来核对。
  wait_text "开始备份" 20 || wait_text "保存" 5
  ui_dump "$ev/scope-page.xml"
  ui_has "$E3_ALBUM" || { log "选范围页首屏没有测试相册 $E3_ALBUM"; return 1; }
  tap_text "$E3_ALBUM" || return 1
  if ui_has "开始备份"; then
    if ui_has "Camera"; then tap_text "Camera" || return 1; fi
    tap_text "开始备份"
  elif ui_has "保存"; then tap_text "保存"; fi
  sleep 4
  # 通知权限等后续系统框：不在本流程判定范围内，一律「不允许」
  if fg | grep -q permissioncontroller; then tap_text "不允许" || true; sleep 2; fi
  app_scope_ids >"$ev/scope.txt"
  scope_is_album || { log "备份范围不是只有测试相册（存下的 [$(cat "$ev/scope.txt")]，测试相册 $(album_bucket_id)）"; return 1; }
  return 0
}

# album_seed：专用测试相册里没有图就推一张——相册要有图才出现在选范围页
album_seed() {
  [ "$(album_count)" -ge 1 ] && return 0
  gen_photos "$E3_STATE/photos-E3seed" 1 E3seed
  push_photos "$E3_STATE/photos-E3seed" || return 1
  album_wait 1
}

# stub_paired：桩里这台手机还在配对列表里
stub_paired() {
  local node
  node=$(cat "$E3_STATE/android-node" 2>/dev/null) || return 1
  eph_ipc devices.list 2>/dev/null | grep -q "$node"
}

# gen_photos <目录> <张数> <前缀>：程序生成、内容各不相同的 jpg（桌面按 hash 判重）
gen_photos() { rm -rf "$1"; python3 -I "$E3_LIB/gen-photos.py" "$1" "$2" "$3" >/dev/null; }

# app_on_welcome：开 App 后停在欢迎页 = 没配对
app_on_welcome() {
  app_start
  wait_text "扫码连接" 6 >/dev/null 2>&1
}

# ensure_paired <证据目录>：手机装的是候选 debug 包、与当前桩配着对；不是就装候选包重新配对。
# 注入类场景的 setup 用它，不关心升级路径。
ensure_paired() {
  eph_ensure "$(cand_daemon)"
  album_seed || return 1
  # 复用的前提还有范围只含测试相册（#1412）：旧配对的范围若是相机相册，推进测试相册的图不会被备份
  if is_debuggable && stub_paired && ! app_on_welcome && scope_is_album; then
    log "手机已与当前桩配对、范围是测试相册，复用"
    return 0
  fi
  install_fresh "$(cand_apk)"
  pair_with_stub "$1"
}

# ensure_photos <张数> <标签>：手机上至少有这么多张本场景的图已备份进桩
ensure_photos() {
  local have
  have=$(eph_photo_count)
  [ "${have:-0}" -ge "$1" ] && return 0
  gen_photos "$E3_STATE/photos-$2" "$1" "$2"
  push_photos "$E3_STATE/photos-$2"
  eph_wait_count "$1" 240
}

# 网格第一格（缩略图被拒时格子里没有文字，取第一个方形大格子）
first_cell_xy() { python3 -I "$E3_LIB/ui.py" square "$UI_XML"; }

# reopen：杀进程重开（手机缩略图缓存只在内存，重开即重拉）
reopen() { app_stop; sleep 1; app_start; sleep 5; ui_dump && dismiss_update; }
