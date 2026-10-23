#!/usr/bin/env bash
# 真机回归的日志判定（#939）：拉手机落盘日志（只看起点之后的行）+ 本机桌面库，按阶段自动判 PASS / FAIL。
# 需要人在手机上点的步骤由人做；本脚本只负责「从日志判定」，可在任意时刻重跑。
#   tools/ios/e3-judge.sh mark                 记下起点（之后的判定只看起点之后的日志行）
#   tools/ios/e3-judge.sh check <phase>        判定一个阶段：foreground-notice | onboarded-at-finish | prewarm-park | no-inactive-catchup | unpair-once | unpair-no-retry | onboarding | wifi | autobackup-on | notify-media | notify-media-dedupe | notify-bgrefresh | commands | retry-failed | photos-log | degraded-stats | icloud-original
#   tools/ios/e3-judge.sh tail [n]             看起点之后的日志尾部
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/apps/ios/build/e3-judge"; mkdir -p "$S"
DEV="${PPASS_DEVICE:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}"
# 桌面库：本机正式桌面的 data_dir（Config.toml），可用 PPASS_DESKTOP_DB 覆盖。
CONF="$HOME/Library/Application Support/P-Pass/Config.toml"
DATA_DIR=$(sed -n 's/^data_dir *= *"\(.*\)"/\1/p' "$CONF" 2>/dev/null | head -1)
DB="${PPASS_DESKTOP_DB:-$DATA_DIR/.ppf/index.sqlite}"
MARK="$S/mark"

pull() {
  local out
  out=$(PPASS_LOG_TAIL=0 "$ROOT/tools/ios/pull-logs.sh" "$DEV" 0 2>&1) || { echo "$out" >&2; return 1; }
  local dir; dir=$(ls -td "$ROOT"/apps/ios/build/device-logs/*/ | head -1)
  local since; since=$(cat "$MARK" 2>/dev/null || echo 0)
  { cat "$dir"/ppass.log.1 2>/dev/null; cat "$dir"/ppass.log 2>/dev/null; } | awk -v s="$since" 'substr($0,1,29) >= s' > "$S/since.log"
}

expect() { # expect <描述> <正则>
  if grep -E -q "$2" "$S/since.log"; then echo "PASS  $1"; grep -E "$2" "$S/since.log" | tail -2 | sed 's/^/        /'
  else echo "FAIL  $1   （未见: $2）"; fails=$((fails+1)); fi
}
absent() { # absent <描述> <正则>
  local n; n=$(grep -E -c "$2" "$S/since.log")
  if [ "$n" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1   （出现 $n 次: $2）"; fails=$((fails+1)); fi
}
count() { # count <描述> <正则> <期望次数>
  local n; n=$(grep -E -c "$2" "$S/since.log")
  if [ "$n" -eq "$3" ]; then echo "PASS  $1（$n 次）"; else echo "FAIL  $1   （期望 $3 次，实际 $n: $2）"; fails=$((fails+1)); fi
}

fails=0
case "${1:-}" in
  mark) date +%Y-%m-%dT%H:%M:%S.000+08:00 > "$MARK"; echo "mark=$(cat "$MARK")" ;;
  tail) pull && tail -n "${2:-60}" "$S/since.log" ;;
  check)
    pull || exit 2
    case "${2:-}" in
      foreground-notice)
        expect "前台发出的通知被展示（#1018）" 'notify: ppass\.[a-z_]+ presented in foreground' ;;
      onboarded-at-finish)
        expect "完成页才记「连过这台电脑」（#1019）" 'onboarded: marked desktop=.* at finish' ;;
      prewarm-park)
        expect "探测前预热 provider（#979）" 'provider prewarm: endpoint bound in'
        expect "退后台且空闲 → 回收（#979）" 'provider: park ok' ;;
      no-inactive-catchup)
        expect "半前台回来不补捞" 'scene: active again without leaving the foreground' ;;
      unpair-once)
        count "主动断开：尽力通知电脑一次（#956 关闭裁决）" 'unpair: desktop=.* (acknowledged|rejected|unreachable)' 1
        expect "本地断开照常完成（provider 撤销）" 'disconnect: provider revoked'
        echo "桌面库 device 表（最近撤销的 iPhone；断开时电脑不可达则不会被撤销，属预期）："
        sqlite3 -readonly "$DB" "select substr(hex(d.node_id),1,10), d.name, p.id is null as unpaired, d.departed_by, datetime(d.departed_at/1000,'unixepoch','localtime') from device_profile d left join pairing p on p.node_id = d.node_id where d.name='iPhone' order by coalesce(d.departed_at,0) desc limit 3" | sed 's/^/        /' ;;
      unpair-no-retry) # 断开后先 mark，再回前台 / 切网络 / 重启 App，然后判
        absent "断开之后不再发起任何 unpair" 'unpair: desktop=' ;;
      onboarding)
        expect "新电脑配对：后台备份意图被清（requested=false）" 'auto-backup prefs: applied on pairing knownDesktop=false requested=false'
        expect "完成页选择了「暂不」" 'onboarding: finish tapped enableBackgroundBackup=false'
        ;;
      wifi)
        expect "关「仅 Wi‑Fi」先弹确认" 'wifi-only: off requested, confirm shown'
        expect "点取消 → 不写盘" 'wifi-only: off cancelled, still on'
        expect "点确认 → 写盘 wifiOnly=false" 'wifi-only: off confirmed'
        expect "确认后真的落盘" 'backup-settings: saved wifiOnly=false'
        expect "再打开 → 落盘 wifiOnly=true" 'backup-settings: saved wifiOnly=true' ;;
      autobackup-on)
        expect "设置里打开后台备份 → 落盘" 'auto-backup prefs: saved on=true' ;;
      notify-media)
        expect "判定输入看到相册权限变差" 'notify: facts mediaAccess=(none|partial)'
        expect "发出「相册权限变差」通知" 'notify: ppass.media_access_revoked posted' ;;
      notify-media-dedupe)
        absent "重启进程后不重复发" 'notify: ppass.media_access_revoked posted' ;;
      notify-bgrefresh)
        expect "判定输入看到后台刷新被关" 'notify: facts .*backgroundRequested=true backgroundRefresh=(denied|restricted)'
        expect "发出「后台刷新被关」通知" 'notify: ppass.background_stopped posted' ;;
      commands)
        expect "取消剩余 N 张成功（#972）" 'command cancelRemaining ok'
        expect "恢复已跳过成功（#972）" 'command restoreSkipped ok'
        absent "命令没有失败（#972）" 'command [a-zA-Z]+ failed' ;;
      retry-failed)
        expect "再试一次成功（#972，有失败张数时才有入口）" 'command retryFailed ok' ;;
      photos-log)
        expect "打开照片页取首页（#987）" 'timeline\.page reason=open cursor=first ok items=[0-9]+'
        expect "缩略图请求有日志（#987）" 'thumb\.get size=256 ok in [0-9]+ms'
        expect "60 秒兜底刷新（#987）" 'timeline\.page reason=fallback cursor=first ok'
        expect "备份新照片后由订阅信号整页刷新（#987）" 'timeline\.page reason=signal cursor=first ok' ;;
      degraded-stats)
        # #1016：只统计不判对错——降级张数（按脱敏 id 去重）与总行数，交给人决定保留降级还是换判据。
        n=$(grep -E -o 'source version degraded for [0-9a-f]{8}' "$S/since.log" | sort -u | wc -l | tr -d ' ')
        echo "INFO  照片源版本降级：$n 张（按 id 去重；行数 $(grep -c 'source version degraded for' "$S/since.log")）" ;;
      icloud-original)
        # #337：测试文件（程序生成、经 Mac「照片」进 iCloud）在手机上原图不在本机，备份时从 iCloud 下载并算出 BLAKE3。
        # 同一 id 的 probe 行（启动时、只读）给出 local=no；original fetched 行（取之前再探一次 local=no）给出字节数、耗时与哈希前缀。
        # 进度回调次数不作判据：真机实测本机原图也会回调。
        expect "启动探测找到测试文件" 'probe: test files found=[1-9]'
        expect "至少一个测试文件原图在 iCloud（启动探测）" 'probe: test=[A-Z] [0-9a-f]{8} .* local=no '
        expect "编辑过的测试文件取编辑后版本（fullSizePhoto=5 / fullSizeVideo=6）" 'probe: test=[A-Z] [0-9a-f]{8} .* selected=(5|6) '
        ok=0
        for id in $(grep -E -o 'probe: test=[A-Z] [0-9a-f]{8} .* local=no ' "$S/since.log" | awk '{print $3}' | sort -u); do
          line=$(grep -E "original fetched $id .* local=no" "$S/since.log" | tail -1)
          if [ -n "$line" ]; then ok=$((ok+1)); echo "PASS  iCloud 下载取原图 $id"; echo "        $line"
          else echo "INFO  $id 还没有从 iCloud 下载成功的 original fetched 行"; fi
        done
        [ "$ok" -gt 0 ] || { echo "FAIL  没有任何测试文件经 iCloud 下载成功"; fails=$((fails+1)); } ;;
      *) echo "未知阶段"; exit 2 ;;
    esac
    [ "$fails" -eq 0 ] && echo "== 阶段 ${2} 通过" || echo "== 阶段 ${2} 失败 $fails 项（明细见 $S/since.log）"
    exit "$fails" ;;
  *) sed -n 2,6p "$0"; exit 2 ;;
esac
