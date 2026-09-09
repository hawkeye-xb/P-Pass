# BUILD-04 本地构建缓存与已合入 worktree 可审计回收（L1）

> 当前节点：已认领，实施中；先交付只预览、显式执行、拒绝不安全 worktree 的清理脚本。
> 协同分支：`work/BUILD-04-local-build-cache-cleanup`
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

待实现。

## 备注

这是开发机本地工程卫生入口，不替代 Git 历史、远端分支或应用数据清理。