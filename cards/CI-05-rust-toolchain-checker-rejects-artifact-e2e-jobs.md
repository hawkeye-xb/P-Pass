# CI-05 Rust toolchain checker rejects CI-02 artifact consumers

> ⬜ 状态：未开工
> 级别：L1 · 阻塞：无

## 问题

CI-02 把 `e2e.yml` 的 release 编译收敛到独立 `build` job，`e2e` 与
`scenarios` 改为下载已构建产物并运行剧本；但
`tools/check-rust-toolchain-ci.sh` 仍要求这两个下游 job 各自出现 Cargo
命令。于是 CI Rust 的「Verify Cargo workflows use rust-toolchain.toml」
对正确的 artifact-consumer 结构报错，当前 main CI Rust 红。

## 期望行为

工具链检查仍覆盖实际运行 Cargo 的 jobs（包括新的 `build` job），同时接受
只下载并运行已构建二进制的 `e2e`/`scenarios` jobs；不放宽其他 workflow
或绕过 Rust 工具链的单一真相约束。

## 验收标准

- [ ] 修复后 `bash tools/check-rust-toolchain-ci.sh` 退出 0，并继续验证所有
  实际 Cargo job 都含 `tools/setup-rust-toolchain.sh`。
- [ ] 反证：移除 `e2e.yml` 的 `build` job 工具链 setup 或将实际 Cargo job
  的 setup 改坏，检查必须退出非零。
- [ ] CI Rust 的该检查步骤与整条 workflow 成功。
- [ ] 收尾：更新 PROGRESS.md、docs/QUEUE.md 与 ROADMAP.md。

## 范围

只准动：
- `tools/check-rust-toolchain-ci.sh` 及其必要测试
- 若检查的 job 事实与 workflow 不符，最小化修改 `.github/workflows/e2e.yml`
- 本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`

不准动：
- Rust 版本值或 `rust-toolchain.toml`
- CI-02 的「release 二进制只编一次」设计

## 阻塞与依赖

无。根因已由 CI Rust run `34319046165` 与本地
`bash tools/check-rust-toolchain-ci.sh` 复现：`e2e.yml:e2e` 与
`e2e.yml:scenarios` 被错误要求包含 Cargo run 命令。
