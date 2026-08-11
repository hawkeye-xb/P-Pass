# LIC-01 补 AGPL-3.0 LICENSE 文件　级别 L0

用户 2026-08-12 指令：「LIC-01（队列里，L0）：补 AGPL-3.0 LICENSE 文件，
照卡面做」。**卡面文件在队列目录缺失**（.claude/cards/ 无 LIC-01 卡；
git 历史、其他 worktree、记忆均无）——按用户指令的意图执行：项目
Cargo.toml 已声明 `license = "AGPL-3.0"`（workspace 继承 + desktop
独立声明），但仓库根缺 LICENSE 文件本身，site/（独立 Astro 项目，landing
自称「开源」）缺 license 字段与声明。

## 实现（标准做法）

- 根 `LICENSE`：GNU 官方 AGPL-3.0 全文（2026-11-19 版，661 行，
  取自 https://www.gnu.org/licenses/agpl-3.0.txt）+ 头部项目声明
  （P-Pass licensed under AGPL-3.0, Copyright (C) 2026 Hawkeye XB）。
- `site/LICENSE`：简短声明（指向仓库根 LICENSE，单源不重复全文）。
- `site/package.json`：+ `"license": "AGPL-3.0"`。
- `apps/desktop/package.json`：+ `"license": "AGPL-3.0"`。
- `README.md`：+ License 段（AGPL-3.0 + LICENSE 链接 + 覆盖范围声明）。

## 验证

- `grep -rL "license" --include=Cargo.toml crates/ apps/` 空 → 所有
  crate 均声明（workspace.license = true 继承）。
- LICENSE 全文与 GNU 官方逐字节一致（从官方 URL 下载，仅加头部声明）。

## 挂账

无。LIC-01 卡面缺失已在卡头记录（若用户有原始卡面可对照补验）。

---
