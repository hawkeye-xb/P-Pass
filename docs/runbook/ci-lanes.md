# CI lane 与必需检查（改 workflow 前必读）

[`AGENTS.md`](../../AGENTS.md) 只留一句红线：**job 的 `name:` 不许随手改，必需检查的
job 名必须写死**。理由和细节在这里。

## 什么时候跑什么

- **推分支不触发 CI**：四条 lane 的 `push` 限定 `branches: [main]`。本地快验：
  纯文档 `just ci-docs`，动了代码 `just ci`。
- **开 PR 才跑 lane**，分两档：
  - `ci-rust` / `ci-desktop`：workflow 层**不设** `pull_request.paths`（CI-07 #189）。
    它们的检查在 `main` 的必需列表里，而被 paths 跳过的 workflow **根本不汇报状态**，
    必需检查会永久停在 Pending 并挡住合并——带 paths + 设必需 = 自锁。
  - 跳过被下放到 job 层（CI-11 #255）：`changes` job 用 `tools/ci-needs-full-lane.sh`
    判断，纯文档改动时下游 job 被 `if:` 跳过。被 `if:` 跳过的 job 汇报 `skipped`，
    `skipped` 对必需检查算通过（PR #260 实测）。
  - `ci-android` / `site` / `ci-docs` 仍按 paths 只在改到自己域时跑，不进必需列表，
    被跳过无害。

## `tools/ci-needs-full-lane.sh` 的判据

- 判据是 **allowlist**：改动**全部**落在无害清单里才跳过，其余一律跑。往清单里加
  东西前先确认没有测试或构建脚本读它（`assets/i18n/**` 被 diag 测试消费，**不许加**）。
- 两个 lane（CI-17 #373），因为 6 个 job 的依赖面不同：
  - **默认** lane（无害 = `docs/`、`.claude/`、`*.md`）：给 `architecture enforcement`
    与 `ci-desktop` 用（`arch-check.sh` 扫 `apps/**`，桌面壳门禁编的就是 `apps/desktop`）。
  - **`rust-workspace`** lane 把 `apps/**` 也算惰性：给 `clippy` / `test` /
    `test (windows)` / `license+deny` / `fmt` 用（`src-tauri` 是独立 workspace，
    主 workspace 编不到它；`apps/` 的 Rust 由 `ci-desktop` 自己检查）。
- 不带 lane 参数 = 默认 lane，这是向后兼容契约；未知 lane 一律判要跑。
- 自测：`tools/test-ci-needs-full-lane.sh`（两个 lane 都做变异反证）。

## job 名

- **任何 job 的 `name:` 都不许随手改**：`main` 的必需检查列表绑在名字上，改名 = 全部
  PR 永久 Pending。改名和改分支保护必须在同一次操作里成对完成。
- **进必需列表的 job，名字必须是写死的常量，不许用 `matrix` 现算。** 「job 被 `if:`
  跳过」与「`name: xxx (${{ matrix.os }})`」凑在一起时，GitHub 不展开 matrix，只汇报
  一条名叫模板原文的检查，分支保护要的名字一条都不来 ⇒ 永久 Pending（#240 + #261，
  探针 PR #271 撞出）。要跑多平台就拆成多个 job、`name:` 各写死，步骤抽进
  `.github/actions/<x>/action.yml` 共享（`ci-desktop` 的 `desktop-linux` /
  `desktop-windows` 就是这么做的）。
- composite action 里每个 `run` 步骤**必须**显式写 `shell:`；actionlint 默认不扫那个
  文件，语法错误要到 CI 真跑才暴露。

## 核心路径

`.github/core-paths.txt` 圈住的文件（门禁本身、配对 / 身份 / 加密 / 协议、存储与迁移、
更新链、依赖锁）改到了，PR 上 `core review` 需要仓库负责人批准。判定逻辑与语法见
`tools/ci-paths.sh` 头注释，自测 `tools/test-ci-paths.sh`。

## 删接口 / 升依赖时的全 lane 核对

必需检查只是全部 lane 的子集。iOS FFI、Windows test、E2E 这些非必需 lane 专门覆盖
跨端、真进程路径，正是删协议最容易炸的地方。

- 删方法 / 协议：`git grep` 覆盖全仓所有语言（`*.swift` `*.kt` `*.sh` `*.py`、
  `tools/`、`apps/*/Tests`），本地验证按 `.github/workflows/` 的每条 lane 对一遍。
- 改 trait / 门禁清单：除了 `just ci`，再跑 `for t in tools/test-*.sh; do bash "$t"; done`。
- 升依赖：先 `git ls-files '*Cargo.lock'`，每一份锁（主 workspace + `src-tauri`）都要改到；
  本地 `cargo deny fetch` 拉最新公告库再验。
- 批 PR 合并前等**全部** lane 结束，不只看必需检查。
