#!/usr/bin/env bash
# UPD-18（#706）：mirror-latest.yml 的「要不要镜像、镜像哪个 tag」判定。
#
# 为什么抽成脚本：这段判定决定 R2 上 stable 专用的固定 key（P-Pass-latest.*、
# 分端清单、冻结的 manifest.json）会不会被覆盖。它内嵌在 YAML 里时只能拿真 tag
# 去试——而用 test tag 试错，试的那一次本身就是事故。抽出来之后
# tools/test-mirror-resolve-tag.sh 用 stub gh 把三种事件 × test/stable 全跑一遍。
#
# 规则：
#   - R2 **只承载 stable**（客户端侧同一约定：R2UpdateSource 只服务 Stable 通道；
#     test 通道读 GitHub 上的 test-channel 滚动指针，R2 上没有它的东西）。
#     `-test.` tag 无论哪种事件触发（含手动 dispatch）一律跳过。
#     2026-10-08 之前这里不排除 test：test tag 自动 publish 成 prerelease ⇒
#     workflow_run 触发 ⇒ 它就是「最新」⇒ stable 的下载包、分端清单、冻结件
#     全被 test 覆盖，stable 设备会被推 test 包（isNewer: 0.9.3-test.1 > 0.9.2）。
#   - 「最新」只在非 test 的 v* release 里比：否则 test 发布之后，stable 那次的
#     重跑会被误判成「不是最新」而跳过。
#   - release 还没建 / 仍是 draft ⇒ 跳过，等 release published 兜底（原语义）。
#   - workflow_dispatch 不比「最新」：手动补镜像旧版本是它的用途（原语义）。
#
# 输入（环境变量）：EVENT、INPUT_TAG、RELEASE_TAG、RUN_REF、GITHUB_REPOSITORY；
#   依赖 PATH 上的 gh（测试里换成 stub）。
# 输出：追加到 $GITHUB_OUTPUT（未设置时打到 stdout）——skip=true，或 tag= / version=。
set -euo pipefail

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
skip() { echo "::notice::$1"; echo "skip=true" >> "$OUT"; exit 0; }

case "${EVENT:-}" in
  workflow_dispatch) TAG="${INPUT_TAG:-}" ;;
  release)           TAG="${RELEASE_TAG:-}" ;;
  workflow_run)      TAG="${RUN_REF:-}" ;;
  *) echo "::error::未知事件 '${EVENT:-}'"; exit 1 ;;
esac

# Release 被手动 dispatch 时 head_branch 是分支名，不是 tag——跳过，要镜像就手动触发本 workflow。
[[ "$TAG" == v* ]] || skip "'$TAG' 不是 v* tag，跳过"
[[ "$TAG" != *-test.* ]] || skip "$TAG 是 test tag——R2 只承载 stable，跳过（test 通道走 GitHub test-channel 指针）"

# release 可能还没建：正式版 tag 是 Release 跑完（workflow_run 触发）之后
# 人工才发 release，这之前查必然 not found——跳过即可，等 release published 兜底。
if ! DRAFT=$(gh release view "$TAG" -R "$GITHUB_REPOSITORY" --json isDraft -q .isDraft 2>/dev/null); then
  skip "$TAG 的 release 还没建（Release 跑完→人工发布前的空窗），跳过，等 release published 触发"
fi
[ "$DRAFT" != "true" ] || skip "$TAG 仍是 draft，等人工发布后由 release published 触发"

if [ "$EVENT" != workflow_dispatch ]; then
  NEWEST=$(gh release list -R "$GITHUB_REPOSITORY" --exclude-drafts -L 50 \
    --json tagName,publishedAt \
    -q '[.[] | select(.tagName | startswith("v")) | select(.tagName | contains("-test.") | not)] | sort_by(.publishedAt) | last | .tagName // empty')
  if [ -z "$NEWEST" ]; then
    echo "::error::查不到已发布的非 test v* release，无法判断 $TAG 是否最新"; exit 1
  fi
  [ "$NEWEST" = "$TAG" ] || skip "$TAG 不是最新发布的 release（最新是 $NEWEST），跳过，免得旧包覆盖新包"
fi

echo "tag=$TAG" >> "$OUT"
echo "version=${TAG#v}" >> "$OUT"
