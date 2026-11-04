# owner 命令：分拣、出 test 包、记想法、停下

这些命令由 agent 在需要时跑（分拣新诉求、出 test 包、记想法、停下交人）。命令自带判定：红了或判定不了，就写 issue（`status:blocked`）
或评论到对应的卡、PR，然后非 0 退出。不补做、不绕过、不改判定，接着做别的。
脚本在 `tools/flow/owner-*.sh`，测试是 `tools/test-flow-owner.sh`（`just ci` 与 `just ci-docs` 都会跑）。

## 开工自检（doctor）

每条 owner 命令开头都会先跑 `just doctor`（`tools/flow/doctor.sh`）。它在你自己的外壳里检查：
当前目录是主副本或它的 worktree、bash 能否真执行（Windows 上必须是 Git Bash，不能是 WSL 桩）、
本地提交拦截已装、gh 能读本仓库 issue、提交身份在 `.github/allowed-identities.txt` 里、磁盘 ≥ 15G。
私仓模式与在线设备只报不判。任一必需项不满足就非 0 退出并打印怎么修，修好再重跑。

- 私仓：主副本旁边有 `../private` 就是**完整模式**；没有就是**协作者模式**——不写不公开内容，
  遇到要写私仓的活，`just stuck <号> "需要写私仓，本机是协作者模式"` 停下。
- `just owner-stuck` 是停下的出口，doctor 不过时也能用。
- 根目录放了 `.ppass-verify-clone` 标记的克隆是 Windows 回归专用克隆，doctor 看到就拒绝在里面开工。

## 命令

| 步骤 | 命令 | 通过时最后一行 |
|---|---|---|
| 记想法（任何会话） | `just idea "<原话>" [--discuss] [--from <来源>]` | `IDEA DISCUSSION #N` 或 `IDEA ISSUE #N status:inbox Feature` |
| 分拣新诉求 | `just triage <号> <方案文件>` | `TRIAGE <号> ready \| needs:product \| blocked` |
| 出 test 包 | `just release-test <端...>` | `RELEASE-TEST OK v<X.Y.Z>-test.N <端...>` |
| 停下 | `just owner-stuck "<原因>" [--issue N \| --pr N] [--product "<一>" "<二>"] [--log 文件]` | `ok: ...` |

退出码：0 通过；1 停下了（已写 issue 或评论）；2 拒绝（用法错，或前置条件没满足，提示里给了下一条命令）。
看到 1 就不要重试同一条命令，先处理 issue。

## 每一步判什么

**idea**：默认建 Discussions 的 Ideas 帖，正文是原话（一字不改）加来源和日期，不进看板。`--discuss` 建
`status:inbox` 的 issue，类型设成 Feature。同标题已有打开的帖子或 issue 时，追加评论，不重复建。

**triage**：方案由模型写进一个 markdown 文件，去向由脚本判。方案必须有这些字段：`**做法**`、`**涉及端**`、
`**数据**`、`**用户可见行为**`、`**隐私**`、`**风险**`、`**范围**`（后面跟 ``` 代码块）、`**验收场景**`；
没有的写「无」。缺字段就拒绝。分流规则：

1. 范围命中核心：方案要有 `**ADR**：docs/decisions/<文件>.md`，而且在 `origin/main` 上是「已采纳」，
   否则打 `status:blocked`，写明先定 ADR。有就打 `core` 标签，接着往下判。
2. 用户可见行为、隐私、数据任一项不是「无」，或者范围碰到界面与文案路径（i18n、设计 token、
   Android `res/` 与 `ui/`、桌面前端、iOS 界面、站点、更新说明），即使方案写了「无」，也打 `needs:product`。
   这时方案必须有 `**选项一**` 和 `**选项二**`，各写做法与影响，否则拒绝。
   例外：产品取向已经定过的，写 `**产品定案**：docs/decisions/<文件>.md，产品负责人 <日期> 已确认`。
   引用的方案必须全部在 `origin/main` 上是「已采纳」，字段里必须写明产品负责人确认，任一不满足就拒绝；
   满足就不打 `needs:product`、不要选项，按第 3 条走。写「无」等于没写。
3. 其余打 `status:ready`。

范围、验收场景、是否核心写进任务卡的对应字段（本地 hook 和 `just verify` 读这几处），其余内容写进正文末尾的
「实施方案」段。写回之后，脚本用 hook 的同一套解析再读一遍范围，读不出来就不写。

**release-test** 的判定：

- 版本号取远端最新 `v<X.Y.Z>-test.N` 的 N+1。X.Y.Z 必须高于 `release/versions.json` 里每一端的正式版本号，
  否则 test 设备收不到；不满足时给出建议的 `--base`。
- 触发发版之前先在 `origin/main` 上本地跑 `tools/release/plan-builds.sh`，它判「构建」的端必须正好等于参数里的端。
- test tag 没有手写更新说明（[规则](../release-notes-rules.md)），脚本只做校验。
- 发版入口是手动触发 `release.yml`（`release=true`，tag 填算出的新 tag）：脚本在一条临时分支（指向判定用的 main 提交）上触发，等这次 run，跑完删临时分支；**脚本不推 tag**，tag 由流程在发版前验证全绿后才建。绿了再核对 test-channel 里各端清单的 version。
- 发版前验证就红了：没有建 tag，同一个版本号可直接重试。tag 已建（构建阶段红）：tag 保留不动，下一次用 `-test.N+1`；这类旧的 test 草稿与 tag 会在下一次成功的 test 发布时由 `point-test-channel.sh` 清掉（被 test-channel 清单指向的保留）。
- 正式版本号、`--formal` / `stable` / `publish` 一律拒绝。正式发布只由产品负责人在网页上做。

## 产品取向的问题

用户感知的行为、隐私、数据去留这类问题不由 owner 定。用产品语言写两个选项，然后接着做别的卡：

```bash
just owner-stuck "导入时遇到重复照片怎么办" --product "保留两份，占盘翻倍" "只留一份，省空间"
```

脚本会开一个打了 `status:blocked` 与 `needs:product` 的 issue。少给一个选项会被拒绝。
