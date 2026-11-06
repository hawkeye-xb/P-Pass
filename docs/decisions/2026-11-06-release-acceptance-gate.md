# 发版闸接进 release.yml：按「[验收] <正式 tag>」找台账

- 状态：已采纳
- 日期：2026-11-06
- 采纳：产品负责人 2026-11-06「可以，采纳」，针对 [#1486 评论](https://github.com/hawkeye-xb/P-Pass/issues/1486#issuecomment-6679133286) 的修订方案
- 关联：#1471（按版本验收）、#1486（按本方案实现）、#1497

## 结论

把已有的台账判定接进 Release，让 Release 自己去跑这道判定。不加新规矩，不加 workflow 输入，不留旁路。

## 背景

#1471（PR #1484）把验收单位从 PR 改成了版本，规矩是「台账清零才出正式版」，判定在
`tools/flow/release-acceptance.sh`（内部调 `release-scope.sh --check`）。但这道判定没有接进
`.github/workflows/release.yml`，现在只能靠 owner 发版前记得手动去跑。`release.yml` 属于核心路径，
要改它，必须先有一份已采纳的方案。

## 决定

1. **位置**：在 `release.yml` 的 `plan-builds` job 里，「发版入口守卫（#1349）」之后加一步。
   - 触发条件：只在 `release=true`、并且 tag 是正式形状 `vYYYY.M.N` 时运行。
   - 所有构建 job 都依赖 `plan-builds`，所以这一步红了，就不会构建、不会上传 TestFlight，也不会建 tag 和草稿。
2. **找台账**：正式 tag 本身就是批次号（`docs/RELEASING.md` UPD-13），台账按批次建，标题统一叫
   「[验收] <正式 tag>」，例如「[验收] v2026.11.2」。
   - 守卫按这个标题精确匹配 open 和 closed 的 issue。
   - 没有匹配、或者匹配到不止一张，都判红。
3. **判定**：调用 `tools/flow/release-acceptance.sh <台账号> <本次构建提交>`。
   - 候选 ref 用 `github.sha`。
   - 退出码不是 0 就失败，并把待验项写进 job 摘要。
   - workflow 里不另写一份判定。
4. **权限**：`plan-builds` job 加 `issues: read` 和 `pull-requests: read`，不碰任何签名 secret。
5. **文字同步**：下面这几处的写法统一改成「[验收] <正式 tag>」：
   - `release-scope.sh` 头注释
   - `docs/runbook/acceptance-sop.md`
   - AGENTS.md「按版本验收」

   同时，「接进 release workflow 另立方案」这句改成「已接入」。`docs/RELEASING.md` 的发版步骤里写明：正式版发版前必须已有这张台账。
6. **测试**：照 `tools/test-release-version-source.sh` 的做法，按 step 名从 `release.yml` 里抽出守卫脚本，用假的 `gh` 跑下面几种情况。反证是去掉判定这一步后，后两种情况必须转红。
   - 台账全勾 → 过
   - 有一项没勾 → 红
   - 没有台账 → 红
   - 同名台账两张 → 红
   - test tag → 不查

## 理由

- **要保证的事**：正式版草稿一建出来，离 publish 只差一次点击。所以候选版里用户看得见、却还没验的改动，不能变成一份可以 publish 的草稿；而且这件事不能靠人记得去查。
- **标准做法**：发布流水线在最前面放一道 fail-fast 的预检，不满足就什么都不做。本仓库已经有同类先例，就是发版入口守卫（#1349）。
- **为什么不用 GitHub Environment 的 required reviewers**：它只认「谁点了批准」，认不出「台账有没有清零」，所以不采用。

## 后果

- 下一个正式版之前，必须先建好「[验收] <正式 tag>」台账。建台账的时机是出第一个 test 包时，用 `just release-scope --ledger <号> --pkg <test tag>`。没有台账，正式版就发不出来。
- 某一项确实不用验时，在台账里把它勾上，行尾写「结论：免验，理由…」。这是现有的出口，不另设旁路。
- 读 GitHub 失败时判红（fail-closed）。这一步在建 tag 之前，所以修好后可以用同一个 tag 号重跑。

## 备选

- **加 workflow 输入，手填台账号**：不选。tag 已经能唯一确定台账，再让人手填，就是多一道人工步骤，也多一处可能填错。
- **加紧急旁路输入**：不选。台账里逐项写「免验」已经够用，而且每一次放行都能逐项查到理由。
- **把闸放在 `create-draft` 前面**：不选。iOS job 不依赖 `create-draft`，会先把包传进 TestFlight；而且要白跑约 40 分钟的构建才会红。
