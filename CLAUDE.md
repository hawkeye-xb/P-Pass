# P-Pass — Claude Code 专属说明

本仓库的执行规范是**模型无关**的，只有一份，在根目录
[`AGENTS.md`](AGENTS.md)——不管你是 Claude Code、Kimi 还是别的 agent，先读它。

本文件只放 Claude Code 这个工具本身特有、其他 agent 用不到的内容。不要在这里
重复 `AGENTS.md` 已写的规矩，改一处即可，改两处必然漂移。

## 按需分配模型（验收人 2026-10-13 定）

主会话每次调用工具都带着整段上下文计费；机械活不需要强模型，也不需要这么长的历史。

- **交给子 agent，用便宜模型**（Agent 工具的 `model` 参数选 `haiku`，或 `sonnet`）：
  界面点击、adb 操作、等 CI、日志检索、哈希对账、按 SOP 逐条跑回归用例。
  prompt 里写清楚命令、脚本路径和预期输出，只要结论回来。
- **主会话只做**：根因分析、方案设计、改代码、判定结果、写报告。
- **先把脚本写对再跑**：失败一次就停下来想清楚，不要边跑边改、来回试。
- 长流程（如全量回归）开始前就按上面拆好，不要跑到一半才拆。

## 开 PR 后立即打开 PR 监控（Claude Desktop，产品负责人 2026-11-05 定）

`AGENTS.md`「交付流程」要求开 PR 的会话把它推进到合入。在 Claude Desktop 里由 app 的 PR 监控唤醒会话：

- `just done` 末尾打印 `PR-CREATE: gh pr create …`。用 Bash 工具**直接**运行冒号后面那条命令（不包进脚本、
  不放后台），app 才把这个 PR 记为本会话所开；`just done` 自己不开 PR。
- 运行后立刻调 `set_monitor`，`auto_fix`、`address_comments`、`auto_archive_on_close` 三项全开（先 `get_status`，
  没报出这个 PR 就 `bind_pr`）。app 没有全局默认开关，每个 PR 都要开。
- 只有本会话直接运行 `gh pr create` 开的 PR 能由会话打开 `auto_fix`；事后按分支绑上的开不了，
  把报错原文报给 owner，不换花样重试。
- 打开后不轮询 CI（不用 `/loop`、定时任务或反复 `gh pr checks`），等 CI 红、新评审意见、冲突把会话唤醒再处理。
