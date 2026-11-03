# #1321 onboarding 闸门（docs/decisions/2026-11-03-onboarding-gate.md）：
# 全新安装 → 配对 → 决定页；杀进程重开仍是决定页；主按钮被拒 → 系统选图，取消回决定页；
# 次入口选一张 → 落「连过」进照片页；清数据重来，主按钮全部允许 → 选范围页 → 开始备份 → 落「连过」进照片页；
# 断开后连回同一台电脑 → 不再出决定页。
# 判据只读日志（logcat 里 `onboarding: decision shown` / `onboarding: marked onboarded via=…`）、界面文字与前台窗口。
# 部分照片权限（Android 14「选择照片」）由 JVM 单测 decision_main_button_lands_by_photo_permission 钉，真机不造。
DESC="配对后先进决定页；两个出口各自落「连过」；杀进程仍回决定页；连回同一台不再问"
COUNTER=off
TAG="E3OG"

# step <名字>：把当前界面文字、前台窗口、截图存进 $OUT/<名字>.*
step() {
  ui_dump "$OUT/$1.xml" || true
  ui_texts "$OUT/$1.xml" >"$OUT/$1.txt" 2>/dev/null || true
  fg >"$OUT/$1.fg" 2>/dev/null || true
  shot "$OUT/$1.png"
}

# picker_up：系统选图在前台
picker_up() {
  local end=$((SECONDS + ${1:-20}))
  while [ $SECONDS -lt $end ]; do
    fg | grep -qE 'photopicker|providers.media' && return 0
    sleep 1
  done
  return 1
}

setup() {
  [ -f "$(cand_apk)" ] || { echo "缺候选包（apps/android 的 assembleDebug 产物；或 E3_ANDROID_APK=…）"; return 1; }
  [ -x "$(cand_daemon)" ] || { echo "缺候选 daemon：$(cand_daemon)"; return 1; }
  rm_photos "PPR_"
  gen_photos "$E3_STATE/photos-$TAG" 3 "$TAG"
  push_photos "$E3_STATE/photos-$TAG"
  eph_start "$(cand_daemon)"
  install_fresh "$(cand_apk)"
  pkg_info >"$EV/pkg.txt"
}

act() {
  # ① 全新安装 → 配对 → 决定页
  logcat_clear
  app_start
  pair_enter_code "$OUT" || return 1
  wait_text "选择要自动备份的照片" 30
  step 1-decision
  # ② 决定页杀进程重开：仍是决定页（「连过」没落盘）
  app_stop; sleep 1; app_start
  wait_text "选择要自动备份的照片" 20
  step 2-decision-after-kill
  # ③ 主按钮 → 权限框拒绝 → 系统选图 → 返回取消 → 回到决定页
  tap_text "选择备份范围"
  sleep 3
  tap_text "不允许" || tap_text "Don't allow" || true
  picker_up 20
  step 3-after-deny
  A shell input keyevent KEYCODE_BACK
  sleep 3
  wait_text "选择要自动备份的照片" 15
  step 3-after-cancel
  # ④ 次入口「先挑几张试试」→ 选一张 → 照片页
  tap_text "先挑几张试试"
  picker_up 20
  sleep 2
  ui_dump && tap_xy "$(first_cell_xy)"
  sleep 1
  tap_text "完成" || tap_text "添加" || tap_text "Done" || tap_text "Add" || true
  sleep 5
  wait_text "照片" 20
  step 4-after-pick
  logcat_save "$OUT/logcat-pick.txt"

  # ⑤ 清数据重来（新身份）：主按钮 → 全部允许 → 选范围页 → 开始备份 → 照片页
  app_stop
  A shell pm clear "$PKG" >/dev/null
  logcat_clear
  app_start
  pair_enter_code "$OUT" || return 1
  wait_text "选择要自动备份的照片" 30
  tap_text "选择备份范围"
  sleep 3
  tap_text "全部允许" || tap_text "Allow all" || true
  wait_text "开始备份" 20
  step 5-scope-page
  tap_text "开始备份"
  sleep 4
  if fg | grep -q permissioncontroller; then tap_text "不允许" || true; sleep 2; fi
  wait_text "照片" 20
  step 5-after-start
  logcat_save "$OUT/logcat-scope.txt"

  # ⑥ 断开 → 连回同一台电脑：不再出决定页
  tap_text "设置"
  sleep 2
  tap_text "更多"
  wait_text "存储电脑" 10
  tap_text "存储电脑"
  wait_text "断开与这台电脑的连接" 10
  tap_text "断开与这台电脑的连接…"
  wait_text "断开连接？" 10
  tap_text "断开"
  sleep 3
  step 6-after-disconnect
  logcat_clear
  pair_enter_code "$OUT" || return 1
  sleep 8
  step 6-after-reconnect
  logcat_save "$OUT/logcat-reconnect.txt"
  runas cat files/onboarded_desktops.json >"$OUT/onboarded.json" 2>/dev/null
  cp "$EV/pkg.txt" "$OUT/pkg.txt"
}

judge() {
  local d="$1" desk
  # 记录按桌面 daemon node id 记；取 ⑤ 落盘日志里的 desktop=<前 8 位>
  desk=$(sed -n 's/.*marked onboarded via=scope desktop=\([0-9a-f]*\).*/\1/p' "$d/logcat-scope.txt" 2>/dev/null | head -1)
  check "① 配对后进决定页" has_line "$d/1-decision.txt" '选择要自动备份的照片'
  check "① 日志：onboarding: decision shown" has_line "$d/logcat-pick.txt" 'onboarding: decision shown'
  check "② 杀进程重开仍是决定页" has_line "$d/2-decision-after-kill.txt" '选择要自动备份的照片'
  check "③ 主按钮被拒 → 系统选图" has_line "$d/3-after-deny.fg" 'photopicker|providers\.media'
  check "③ 选图取消 → 回决定页" has_line "$d/3-after-cancel.txt" '选择要自动备份的照片'
  check "④ 次入口选完 → 落盘（via=pick）" has_line "$d/logcat-pick.txt" 'onboarding: marked onboarded via=pick'
  check "④ 次入口选完 → 进照片页（底栏在）" has_line "$d/4-after-pick.txt" '^设置$'
  check "④ 次入口选完 → 离开决定页" no_line "$d/4-after-pick.txt" '选择要自动备份的照片'
  check "⑤ 全部允许 → 首次选范围页（开始备份）" has_line "$d/5-scope-page.txt" '开始备份'
  check "⑤ 开始备份 → 落盘（via=scope）" has_line "$d/logcat-scope.txt" 'onboarding: marked onboarded via=scope'
  check "⑤ 开始备份 → 进照片页（底栏在）" has_line "$d/5-after-start.txt" '^设置$'
  check "⑤ 开始备份 → 离开决定页" no_line "$d/5-after-start.txt" '选择要自动备份的照片'
  check "⑥ 断开后回到欢迎页" has_line "$d/6-after-disconnect.txt" '扫码连接家里的电脑'
  check "⑥ 连回同一台：进照片页（底栏在）" has_line "$d/6-after-reconnect.txt" '^设置$'
  check "⑥ 连回同一台：不出决定页（界面）" no_line "$d/6-after-reconnect.txt" '选择要自动备份的照片'
  check "⑥ 连回同一台：日志已抓到" [ -s "$d/logcat-reconnect.txt" ]
  check "⑥ 连回同一台：日志无 decision shown" no_line "$d/logcat-reconnect.txt" 'onboarding: decision shown'
  check "⑥ 断开后记录还在这台（desktop=${desk}）" has_line "$d/onboarded.json" "\"${desk:-none}"
  check "全程无 FATAL" bash -c "! cat '$d'/logcat-*.txt | grep -q 'FATAL EXCEPTION'"
  verdict
}

teardown() {
  rm_photos "PPR_"
}
