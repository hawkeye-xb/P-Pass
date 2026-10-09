#!/usr/bin/env bash
# REL-12（#711）：release.yml · create-draft ·「Release notes presence (#741, warn only)」。
# 原样抽自 workflow 内嵌 bash；只在正式 tag 上跑、continue-on-error 仍写在 workflow 里。
#
# 正式 tag 某端版本号涨了、却没有该版本的手写更新说明 ⇒ `::warning::`，**不阻断**
# （允许「无用户可见变更」——弹窗显示默认文案）。比较口径与版本门禁相同
# （上一个 v* tag 的 release/versions.json）。release-notes.mjs warn-missing 恒退出 0。
#
# 输入（显式）：TAG（step env）、RUNNER_TEMP；工作区需含全部 v* tag（checkout fetch-depth: 0）。
set -euo pipefail
: "${TAG:?TAG 未设置（step env）}"
: "${RUNNER_TEMP:?RUNNER_TEMP 未设置}"
cd "$(dirname "$0")/../.."

PREV=$(git tag -l 'v*' --sort=-v:refname | grep -vx "$TAG" | head -1 || true)
if [ -n "$PREV" ] && git cat-file -e "$PREV:release/versions.json" 2>/dev/null; then
  git show "$PREV:release/versions.json" > "$RUNNER_TEMP/prev-versions.json"
else
  echo '{}' > "$RUNNER_TEMP/prev-versions.json"
fi
node tools/release-notes.mjs warn-missing \
  --prev-versions "$RUNNER_TEMP/prev-versions.json" --versions release/versions.json
