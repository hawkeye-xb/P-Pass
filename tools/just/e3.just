# E3 本地真机验证、开发安装与版本恢复配方

# 本地真机验证（E3，V1/V2）：按改动路径判定涉及的端，构建候选、装到真机跑冒烟 + issue「验收场景」点名的场景，
# 证据写 evidence/（不进 git），最后一行 VERIFY PASS|FAIL。写场景、读结果见 docs/runbook/e3.md。
#   just verify 1234            卡上写明需要真机验证时
#   just verify --smoke android 只跑某端冒烟
#   just verify --all           全量场景库（V2，合批前）
# 卡上写明需要真机验证时才跑。
verify *args:
    tools/e3/verify {{args}}

# 研发本地看改动：增量编译 → 取设备锁（手机被占就拒绝）→ 覆盖安装（不卸载）→ 打开。见 docs/runbook/e3.md。
#   just dev android [页面] [--fresh]   just dev ios [页面] [--fresh]   just dev mac（装回：just restore）
# #1820：本地构建注入构建时间 PPF_BUILD_STAMP（`MM-DD HH:MM`），版本行后面显示，两个包一眼分出新旧；
# 正式/CI 构建不经过这条 recipe，没有这个变量，版本行不变。已经显式设置 PPF_BUILD_STAMP 时沿用（测试用）。
dev *args:
    #!/usr/bin/env bash
    set -euo pipefail
    export PPF_BUILD_STAMP="${PPF_BUILD_STAMP:-$(date '+%m-%d %H:%M')}"
    exec tools/e3/dev {{args}}

# 把测试设备装回指定版本（先取设备锁）：just restore mac <tag> | just restore mac --snapshot
restore *args:
    tools/e3/restore {{args}}

# tools/e3 的自测（#1500）：脚本语法、场景接口齐全、判定回放（fixtures 的 pass 必须过、fail 必须红），不碰设备。
# macOS 专有的段（lockf、ditto）在脚本内按平台跳过，其余在 ubuntu 上照跑。
e3-test:
  @bash tools/test-e3.sh
