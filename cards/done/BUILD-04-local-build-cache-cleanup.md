# BUILD-04 本地构建缓存与已合入 worktree 可审计回收（L1）

> ✅ 状态：代码已合并（commit `186a9df`），2026-09-09 归档
> 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

隔离 worktree 的 Rust/Android/desktop 构建分别产生 `target/` 缓存；任务已合入后没有统一、可验证的回收入口。长期累积会耗尽开发机磁盘，而人工用宽泛删除命令又可能删掉未合入或正在构建的工作。

## 期望行为

仓库提供一个本地、可重复运行的清理入口：默认只列出候选项和可回收大小；只有显式 `--apply` 才会删除。编译缓存可独立清理；worktree 只有同时满足“已注册、干净、HEAD 已被 `origin/main` 包含、没有构建进程”时才能移除。脚本绝不删除当前 worktree、未合入分支或有未提交改动的 worktree。

## 验收标准

- [ ] 不带 `--apply` 运行清理命令只输出计划，不删除文件。
- [ ] `--apply --targets` 在隔离测试仓库移除主工作区与注册 worktree 的 `target/`，但不删除源码/worktree。
- [ ] `--apply --worktrees` 在隔离测试仓库只移除 clean 且已合入 `origin/main` 的注册 worktree；dirty 或未合入 worktree 保留。
- [ ] 有构建进程的 worktree 被跳过，不在活跃构建中删除缓存或工作目录。
- [ ] `just queue-check` 与脚本测试均通过；脚本使用说明写进 `justfile`。

## 范围

- 只准动：`tools/clean-local-builds.sh`、`tools/test-clean-local-builds.sh`、`justfile`、本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`。
- 不准动：产品代码、CI、GitHub Actions、任何用户数据或 `.ppf/` 存储。

## 阻塞与依赖

无。

---

## 实施记录

- 新增 `tools/clean-local-builds.sh` 与 `just cleanup-local`：默认只预览；删除必须同时写 `--apply` 和 `--targets`、`--worktrees` 或 `--all`。
- `--worktrees` 只移除已注册、clean、其 `HEAD` 已合入 `origin/main`、不是当前 worktree 且没有活动 Cargo/Rustc/Gradle/Node 构建的目录；任何不满足条件的目录明确输出 `SKIP` 原因。`--targets` 只删非符号链接的 `target/`，同样跳过活动构建。
- `just test-cleanup-local` 在临时 Git fixture 实测：默认预览不删；显式缓存清理保留所有源码；已合入 clean worktree 被移除；dirty、未合入与活动构建 worktree 均保留。另以 `--apply` 无 scope 退出 2 验证显式范围门。

## 备注

这是开发机本地工程卫生入口，不替代 Git 历史、远端分支或应用数据清理。