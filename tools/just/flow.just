# 统一协作流程（tools/flow/flow.py）、owner 与发布链演练配方

start n *args:
    python3 -B -I tools/flow/flow.py start {{n}} {{args}}

done *args:
    python3 -B -I tools/flow/flow.py done {{args}}

[positional-arguments]
dispatch *args:
    python3 -B -I tools/flow/flow.py dispatch "$@"

probe-slots *args:
    python3 -B -I tools/flow/flow.py probe-slots {{args}}

# 按版本验收（#1471）：从 git 算候选版相对上一个正式版、用户看得见的改动（PR + 级别 + 卡上的验收场景）。
release-scope *args:
    bash tools/flow/release-scope.sh {{args}}

# 发版前验收门禁（#1471）：台账里候选版的用户可见改动全部已验、验过之后相关文件没再改，才绿。
release-acceptance ledger *args:
    bash tools/flow/release-acceptance.sh {{ledger}} {{args}}

stuck n reason:
    python3 -B -I tools/flow/flow.py stuck {{n}} "{{reason}}"

# 合入前全量独立只读评审（彻底废除增量盲区，审阅完整 origin/main...HEAD diff）。
review pr *args:
    python3 -B -I tools/flow/flow.py review {{pr}} {{args}}

# CI 评审 job（tools/flow/ci-review.sh）的判据测试：假 gh + 假 agent，结论写成 review/agent。
flow-ci-review-test:
    @bash tools/test-ci-review.sh

flow-engine-test:
  @python3 -B -I tools/test-flow.py

# PR 卡点：列出未过的检查、未解决的评审线程、冲突、是否开了自动合入。
pr-status pr:
    bash tools/flow/pr-status.sh {{pr}}

# 仓库级多 PR 边沿触发监视器（0 空转 token，状态跃迁才退出）。
[positional-arguments]
pr-watch *args:
    bash tools/flow/pr-watch.sh "$@"

pr-watch-test:
  @bash tools/test-pr-watch.sh

# 回复一条评审线程并标为已解决（线程 ID 用 just pr-status 查）；只关闭用 tools/flow/pr-thread.sh --resolve-only <ID>。
[positional-arguments]
pr-thread id reply:
    bash tools/flow/pr-thread.sh "$@"

# 门的状态：被手动停用的 workflow、发版调用时被跳过的 job、main 的必需检查。
gate-status:
    bash tools/flow/gate-status.sh

flow-gate-status-test:
    @bash tools/test-gate-status.sh

# ── owner 流程 ──────────────────────────────────────────────────────────

# 在 origin/main 上打 test tag 并等 Release 结论（端 ∈ android macos windows ios；正式版拒绝）
release-test +args:
    bash tools/flow/owner-release-test.sh {{args}}

# 收到人类的新想法：默认记进 Discussions 的 Ideas；--discuss 建 status:inbox 的 Feature issue
[positional-arguments]
idea text *args:
    bash tools/flow/owner-idea.sh "$@"

# 极简分拣立项（不再强制 18 字段方案表）
triage issue *args:
    python3 -B -I tools/flow/flow.py triage {{issue}} {{args}}

[positional-arguments]
owner-stuck reason *args:
    python3 -B -I tools/flow/flow.py owner-stuck "$@"

# main 红了自动开卡（tools/flow/main-red.sh）的判据测试：假 gh，每条带反证
main-red-test:
    @bash tools/test-main-red.sh

# REL-12 (#711): 发布链 dry-run——不花真 tag，用假产物 + stub gh + 临时签名密钥，把
# release.yml 的「正式 tag」与「test tag」两条路径（组装清单 → 说明 / 缺失告警 → 签名 →
# 校验 → 镜像判定）按 runner 语义各跑一遍。--keep 保留临时目录排查。
release-dry-run *args:
    tools/release/dry-run.sh {{args}}

# 先跑变异反证，再跑门禁本身；PPF_SMOKE_BIN_DIR=<bundle 目录> 时加跑完整冒烟。
# REL-08 (#510): release 资产里的 .sh 在只含资产的干净目录里必须自足
test-dogfood-assets:
    bash tools/test-dogfood-assets.sh --self-test
    bash tools/test-dogfood-assets.sh
