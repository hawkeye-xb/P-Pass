#!/usr/bin/env bash
# #1546 / REL-07 / #872：test-channel 的**唯一**收敛入口。
#
# 只做清理，不传包、不写清单。所有端的上传 / 指向完成后由 release.yml 的 `cleanup-test-channel`
# job 跑且只跑一次（单点、串行、幂等）：各端 job 并行写同一个 test-channel，谁都没有全局视野；
# 让它们各自清理会删到对方刚枚举出来的资产（2026-11-06 run 42210867452，日志末行
# `no assets match the file pattern`）。设计见
# docs/decisions/2026-11-06-release-test-channel-single-writer.md。
#
# 收敛内容（原 point-test-channel.sh 的第 4、5 步，语义不变）：
#   1. 删掉 test-channel 里**没有任何清单指向的版本**的安装包。按「被引用的版本」而不是
#      「被引用的文件」判，dmg 这类不进清单、但与当前版本配套的包才留得住；不带版本号的文件不动。
#   2. 删掉比被指向的最新版本还旧、且没被指向的 test 草稿（连同 tag）。
#
# 输入：TAG（job env）、GITHUB_REPOSITORY；gh 已登录（GH_TOKEN）。
# 退出码：0 = 收敛完成或没有可收敛的东西（非 test tag / 通道不存在 / 读不到任何清单）；
#         非 0 = 删到一半失败（下一次重跑会继续收敛）。release.yml 把这个非 0 降级为 warning：
#         此时资产已上传、清单已指向，客户端能下载，收敛失败只影响占盘。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设置}"
CH=test-channel

# 正式 tag 不碰 test-channel；非 test tag 直接退出，连 gh 都不调。
[[ "$TAG" == *-test.* ]] || { echo "非 test tag（${TAG}）：没有 test-channel 要收敛"; exit 0; }

if ! gh release view "$CH" >/dev/null 2>&1; then
  echo "test-channel 不存在：没有可收敛的东西"
  exit 0
fi

version_of() { node -p 'require(process.argv[1]).version' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
ch_assets() { gh release view "$CH" --json assets -q '.assets[].name'; }

# 一次枚举，后面只读这一份快照：收敛是单点的，运行期间没有别的 writer。
ASSETS=$(ch_assets)
MANIFESTS=$(printf '%s\n' "$ASSETS" | grep -E '^manifest(-[a-z]+)?\.json$' || true)
if [ -z "$MANIFESTS" ]; then
  # 拿不准就保留：一次瞬时的清单缺失不该把整条通道的安装包与草稿清空。
  echo "test-channel 里没有任何清单：不删安装包与草稿（拿不准就保留）"
  exit 0
fi

# 1. 被任一清单指向的版本才保留
KEEP_DIR="${RUNNER_TEMP:-/tmp}/ch-keep"
rm -rf "$KEEP_DIR"; mkdir -p "$KEEP_DIR"
KEEP=""
# #348：manifest-ios.json 只是 plan-builds 的基线（iOS 包在 TestFlight，不在 test-channel）。
# 它指向的版本要保住 test 草稿与 tag（基线 tag 被删 ⇒ 下次判不了改动 ⇒ 白白构建），
# 但不该把那个版本的 Android / macOS / Windows 安装包也留住：只进 KEEP_DRAFTS，不进 KEEP。
KEEP_DRAFTS=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  gh release download "$CH" -p "$m" -O "$KEEP_DIR/$m" --clobber
  mv_=$(version_of "$KEEP_DIR/$m")
  KEEP_DRAFTS="$KEEP_DRAFTS $mv_"
  [ "$m" = manifest-ios.json ] || KEEP="$KEEP $mv_"
done <<EOF
$MANIFESTS
EOF
while IFS= read -r n; do
  [ -n "$n" ] || continue
  v=${n#P-Pass_}; v=${v%%_*}
  case " $KEEP " in
    *" $v "*) ;;
    *) gh release delete-asset "$CH" "$n" --yes; echo "test-channel：删除没有清单指向的旧包 ${n}" ;;
  esac
done <<EOF
$(printf '%s\n' "$ASSETS" | grep -E '^P-Pass_' || true)
EOF

# 2. 清理旧的 test 草稿（#872）：test tag 自己的 release 只是构建记录。版本没有被任何清单指向、
#    且比被指向的最新版本还旧的 test 草稿连同它的 tag 一起删——它既不是谁的下载来源，也不是
#    plan-builds 的基线。比最新被指向版本新的不动：那可能是正在跑、还没写指针的 test tag。
# shellcheck disable=SC2086 # KEEP_DRAFTS 是空格分隔的版本列表，刻意拆分
NEWEST=$(printf '%s\n' $KEEP_DRAFTS | sort -V | tail -n1)
for t in $(gh release list --limit 200 --json tagName,isDraft \
             -q '.[] | select(.isDraft and (.tagName | contains("-test."))) | .tagName'); do
  v=${t#v}
  case " $KEEP_DRAFTS " in *" $v "*) continue ;; esac
  [ "$v" != "$NEWEST" ] && [ "$(printf '%s\n%s\n' "$v" "$NEWEST" | sort -V | tail -n1)" = "$NEWEST" ] || continue
  gh release delete "$t" --yes --cleanup-tag
  echo "删除旧的 test 草稿与 tag：${t}"
done
