#!/usr/bin/env bash
# REL-12（#711）：发布链 dry-run 的入口（`just release-dry-run` / CI Docs lane 调它）。
# 说明见 tools/release/dry_run.py 文件头。依赖：python3 + PyYAML、node、jq、git、npx
# （tauri signer @tauri-apps/cli@2.11.4，与 release.yml 同版本；首次运行会从 npm 拉取）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "需要 PyYAML：python3 -m pip install pyyaml" >&2; exit 2; }
# 不在仓库里留 __pycache__
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$HERE/dry_run.py" "$@"
