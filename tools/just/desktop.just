# 桌面端（Tauri / macOS dev）与官网设计 token 检查配方

# DESK-15: assets/design/tokens.css must not drift from tokens.json
# 解释器探测同 md-check（理由见 QA-07 注释）。
token-check:
  #!/usr/bin/env bash
  set -euo pipefail
  for py in python3 python py; do
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      exec "$py" ./tools/check-token-drift.py
    fi
  done
  echo "token-check: 找不到可用的 Python 3（试过 python3 / python / py）" >&2
  exit 1

# SITE-04: site 有自己一套生成物（tokens.css / icons），由 site/scripts/*.mjs
# 从 assets/design/ 生成，**不在 token-check 的覆盖范围内**——后者只比数值，
# 而 site 的生成器连文案一起嵌进产物。漏掉的后果实测过：一次只改文案的提交
# 让 site lane 红了 6 天没人发现。
#
# 需要 site/node_modules 就位，所以刻意**没有**挂进 ci / ci-docs（见 SITE-04
# 卡的留白）。动了 assets/design/ 或 site/ 就手动跑一次。
site-check:
  @cd site && npm run tokens:check && npm run icons:check

desktop-dead-components-test:
  @bash tools/test-check-desktop-dead-components.sh

# T-041 桌面壳开发模式（Tauri dev = 前端热更 + 托盘）
# #1115：debug 构建的壳只能经令牌连测试沙盒——先 `just dev-daemon`，再
#   PPF_SANDBOX_DIR=<它 stdout 上 SANDBOX: 后面那个目录> just dev-desktop
# 常驻 daemon（签名 socket）只接受签名的窗口程序，未签名的开发壳连不上它。
dev-desktop:
    cd apps/desktop && npx tauri dev

# macOS 日常开发循环（Xcode 式：每个 debug 构建都组装成 .app、用团队 Developer ID 签名）。
# 窗口连本机真实的签名 daemon，签名校验与正式包一字不差。前端改动走 vite HMR；外壳 Rust
# 改动由 tauri dev 自动重编、签名、拉起；daemon Rust 改动跑 `just mac-dev daemon`。
# 开发版装在 ~/Applications/P-Pass.app（与正式包同 bundle id / LaunchAgent，互斥）：那里是正式包
# （正在运行或只是装着）时一律拒绝，不替换、不备份——先自己退出并移走正式版。退出开发模式：
# Ctrl+C，再装回正式 dmg。
#   just mac-dev            启动 tauri dev（首次需 PPF_DAEMON_PROVISIONPROFILE）
#   just mac-dev daemon     daemon 增量编译 + 签名 + kickstart + 重拉外壳（重拉这步尚未实测）
#   just mac-dev status     只读：看现在装的是哪一版
# 详见 tools/mac-dev.sh 文件头。
# macOS 开发循环：HMR + 签名的 debug 构建，连本机真实 daemon（up|daemon|status）
mac-dev *args:
    tools/mac-dev.sh {{args}}

# #1110：把本地构建的 daemon 组装成签过名的 helper（个人团队 Developer ID + 授权文件）。
# 需 PPF_DAEMON_PROVISIONPROFILE=<授权文件路径>。用途：本机验钥匙串读写、签名形状；
# #1115 起开发壳不连它（见 dev-desktop），要连得用签名的窗口程序。
dev-daemon-helper *daemon_bin:
    tools/daemon-helper-macos.sh dev {{daemon_bin}}
