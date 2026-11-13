# 【E3-6】ADR「验收标准 E3」第 6 条：后台只记录系统实际行为，不据此宣称「拍完立即同步」。
# 做法：备份进行中（大视频传输）把 App 退到后台（UI 测试按 Home，系统真实行为），录下这期间 App 落盘日志；
# 然后回前台让它收场。判定只断言「记录到了后台期间的行为 + 回前台后收场」，对后台期间有没有进度**不做任何断言**
#（ADR 明确：App 被划掉后不保证系统及时唤醒传输）。素材程序生成，测试目录只碰 foldere3-*。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
BIG_MB="${PPASS_E3_FOLDER_BIG_MB_BG:-150}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"
teardown() { ios_pair_allow_stop; desk_stop "$DESK" 2>/dev/null; rm -rf "$WORK"; }

DESC="备份中退后台只记录系统实际行为（不做进度承诺），回前台后收场；后台期间行为以日志为准"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_make_bigvideo "$WORK/big.mp4" "$BIG_MB"
  mkdir -p "$WORK/stage" && mv "$WORK/big.mp4" "$WORK/stage/"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
  # 按 Home 的 UI 测试要先 build-for-testing
  local ios="$REPO_ROOT/apps/ios"
  [ -d "$ios/TransportFFITests/Generated/TransportFFI.xcframework" ] \
    || "$REPO_ROOT/tools/build-ios-transport-xcframework.sh" "$ios/TransportFFITests/Generated" >>"$EV/build.log" 2>&1
  (cd "$ios" && xcodegen generate --quiet) >>"$EV/build.log" 2>&1
  xcodebuild build-for-testing -project "$ios/PPass.xcodeproj" -scheme PPassUI -configuration Debug \
    -destination "id=$IOS_HW_UDID" -allowProvisioningUpdates \
    -derivedDataPath "$ios/build/derived-device" >>"$EV/build.log" 2>&1 \
    || { tail -20 "$EV/build.log" >&2; die "UI 测试构建失败（$EV/build.log）"; }
}

act() {
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"big.mp4\":\"big.mp4\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  # App 由 UI 测试自己带 env 启动（配对+备份一轮），启动后 UIREG_HOME_WAIT 秒按 Home 退后台：
  # devicectl 预先启动的实例会和 automation 会话抢前台（真机实测 automation mode 超时），让 runner 全程管。
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  echo "home planned at +${UIREG_HOME_WAIT:-6}s after launch" >"$OUT/background-timeline.txt"
  xcodebuild test-without-building -project "$REPO_ROOT/apps/ios/PPass.xcodeproj" -scheme PPassUI \
    -destination "id=$IOS_HW_UDID" -only-testing:PPassUITests/FolderPickerDrive/testPressHome \
    -derivedDataPath "$REPO_ROOT/apps/ios/build/derived-device" \
    TEST_RUNNER_UIREG_RUN="$RUN-home" TEST_RUNNER_UIREG_PAIR_LINK="$PAIR_QR" \
    TEST_RUNNER_UIREG_HOME_WAIT="${UIREG_HOME_WAIT:-6}" >"$OUT/home-test.log" 2>&1 \
    || { tail -10 "$OUT/home-test.log" >&2; return 1; }
  echo "backgrounded at $(date '+%T')" >>"$OUT/background-timeline.txt"
  # 后台期录 30 秒系统行为（无承诺：系统此刻做什么就是什么，全部进日志）
  sleep 30
  ios_pull_log "$OUT/ppass-background.log"
  echo "foreground relaunch at $(date '+%T')" >>"$OUT/background-timeline.txt"
  # 回前台收场（已配对；备份若被系统收回执行时间，这里按「遗留续传」继续）
  ios_launch "$OUT" resume "$(jq -cn --arg r "$RUN-resume" '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/resume" "$RUN-resume" 600 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/resume.status.json"; return 1; }
  cp "$OUT/resume.status.json" "$OUT/status-resume.json"
  ios_collect_common "$OUT"
  cp "$OUT/ppass-background.log" "$OUT/ppass-background-copy.log" 2>/dev/null || true
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
}

judge() {
  local d="$1"
  check "登记与收场（回前台后 confirmed 收齐）" has_line "$d/status-resume.json" '"ok" *: *true'
  check "按 Home 的 UI 测试执行了（home 键真的按了）" has_line "$d/home-test.log" 'Executed 1 test'
  check "后台期间系统行为有记录（scene: 状态行在落盘日志里）" has_line "$d/ppass-background.log" 'scene:'
  check "记录里含后台进入与前台恢复两个时点（timeline）" bash -c "grep -q backgrounded \"$d/background-timeline.txt\" && grep -q relaunch \"$d/background-timeline.txt\""
  check "后台期间无任何进度承诺（判据里不存在「后台必须传完」的断言；本行只核对记录存在）" bash -c "[ -s \"$d/ppass-background.log\" ]"
  verdict
}
