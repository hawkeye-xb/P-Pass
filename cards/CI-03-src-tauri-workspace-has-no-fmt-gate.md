# CI-03 桌面壳 workspace 没有 fmt/clippy 门禁，格式漂移无人发现　级别 L0

> ⬜ 状态：未开工
> 级别：L0 · 阻塞：无

## 问题

`apps/desktop/src-tauri` 是**独立 workspace**（ADR-012 刻意如此：桌面壳零业务
逻辑、不依赖内部 crate，庞大的 Tauri 依赖树也就不进主 workspace 的构建）。
代价是：主 workspace 的 `just ci`（`cargo fmt --all -- --check` +
`cargo clippy --all-targets`）**覆盖不到它**，而 `ci-desktop.yml` 对 Rust 侧
只跑 `cargo test --lib`——**全仓没有任何一处检查桌面壳的格式和 lint**。

后果是真的在漂移。2026-08-25 在 `src-tauri` 里跑了一次 `cargo fmt`，
`src/ipc.rs` 两处**与当次改动无关**的既有代码被重排（一个函数签名折行、
一处 `std::fs::write` 调用折行）——说明这些代码从写下起就没被格式化过，
而且没人会发现。

## 期望行为

桌面壳的 Rust 代码和 `crates/` 同一档待遇：格式与 lint 有门禁，红了会被拦。

## 验收标准

- [ ] `ci-desktop.yml` 在 `cargo test --lib` 之前加两步（working-directory
      `apps/desktop/src-tauri`）：`cargo fmt -- --check`、
      `cargo clippy --all-targets -- -D warnings`
- [ ] 先把现存漂移一次性修掉（单独一次 `cargo fmt` 提交），否则新门禁第一次
      跑就红
- [ ] 反证：在 `src-tauri` 里故意写一行未格式化代码 → 新加的 fmt 步骤变红
      （证明门禁真的在看这个 workspace，不是看主 workspace）
- [ ] `just ci` 的语义不变（主 workspace 不去编译 Tauri 树——那正是分开的
      理由，不许为了统一门禁把桌面壳并回主 workspace）

## 范围

- 只准动：`.github/workflows/ci-desktop.yml`、`apps/desktop/src-tauri/**`
  的格式化结果
- 不准动：workspace 拆分本身（ADR-012）；`justfile` 里 `ci` 的组成
  （本机 `just ci` 不该被拖进 Tauri 依赖树的编译）

## 阻塞与依赖

无。⚠️ `.github/workflows/**` 目前由验收人自己在管——开工前先确认由谁动这个
文件。

---

## 备注

顺带记一条：`ci-desktop.yml` 里那句「照片墙窗口对账的回归锁（DESK-09）」的
卡号引用是**旧编号体系的残留**，跟现在的 `DESK-09`（向导吞掉 daemon 启动
错误）不是同一件事。改这个文件时可以顺手把那处注释的卡号说清楚，避免下一个
读的人按卡号去找错的卡。
