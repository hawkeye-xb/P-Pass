# AGENT_PROTOCOL — 铁律与门禁

> 本文档为实施计划 §B 的原文落库。工程门禁由 `tools/arch-check.sh` 和 `.github/workflows/pr.yml` 强制执行。

## §B.1 iroh 隔离规则

**规则：** `iroh` 只允许出现在 `crates/transport/` 中。

**覆盖范围：**
- `.rs` 文件中的 `use iroh...`、`iroh::...`、`extern crate iroh`
- `Cargo.toml` 中的 `iroh = ...` 依赖声明

**执法：** `tools/arch-check.sh` B.1 段以 grep 扫描 `crates/` 目录（排除 `crates/transport/`）。CI 中 `just arch-check` 失败即阻断合并。

## §B.2 平台 cfg 隔离规则

**规则：** 包含 `cfg` 且同行出现 `windows` 或 `target_os` 的代码只允许出现在 `crates/platform/` 中。

**覆盖范围（三种写法，宁误报不漏报）：**
- `#[cfg(windows)]`、`#[cfg(target_os = "...")]`
- `#[cfg_attr(any(...), cfg(windows))]` 等属性宏形式
- `cfg!(windows)`、`cfg!(target_os = "...")` 等编译时宏形式

**执法：** `tools/arch-check.sh` B.2 段以正则 `\bcfg\b.*\b(windows|target_os)\b` 全量扫描
`crates/` 目录（排除 `crates/platform/`）。platform crate 内豁免。

## 铁律摘要

| # | 铁律 | 执法方式 |
|---|------|---------|
| 1 | 只做当前卡 | 人工抽查 diff 范围 |
| 2 | 禁止修改已有测试来让其通过 | 人工抽查 + 快照不变 |
| 3 | 禁止捏造命令输出 | 卡片验收要求贴真实输出 |
| 4 | 凭据不进代码 | `.example` + env 约定 |
| 5 | iroh 只许在 transport | `just arch-check` → B.1 |
| 6 | 平台 cfg 只许在 platform | `just arch-check` → B.2 |
| 7 | 每卡收尾 just 全绿 + PROGRESS.md | CI + 人工抽查 |
