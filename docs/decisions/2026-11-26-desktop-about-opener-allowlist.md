# 桌面端「设置 → 关于」外链按最小权限白名单放行

- 状态：已采纳（产品负责人 2026-11-26 拍板方案一）
- 日期：2026-11-26
- 关联：#2065（四端统一补齐「关于」与帮助反馈入口）、#1120（桌面端最小权限与 `opener:allow-open-url` 作用域收敛）

## 结论

沿用 #1120 的最小权限原则，不放开 `opener:allow-default-urls`，仅在 `apps/desktop/src-tauri/capabilities/default.json` 的 `opener:allow-open-url` `allow` 数组中精确补充 `#2065`「设置 → 关于」所需的 4 条外部链接白名单，使前端 `@tauri-apps/plugin-opener` 的 `openUrl` 能够正常调起系统默认浏览器与邮件客户端。

## 背景

1. `#2065` 要求桌面端（macOS / Windows）「设置 → 关于」在现有壳版本与后台服务版本下方补充外链入口：官网（`https://p-pass.hawkeye-xb.com/` 或 `/zh/`）、常见问题（`/faq/` 或 `/zh/faq/`）、问题反馈邮箱（`mailto:ppass@hawkeye-xb.com`）与 GitHub Discussions（`https://github.com/hawkeye-xb/P-Pass/discussions`）、开源仓库（`https://github.com/hawkeye-xb/P-Pass`）、隐私政策（`/privacy/` 或 `/zh/privacy/`），点击后调用系统默认浏览器或邮件客户端打开。
2. 目前 `apps/desktop/src-tauri/capabilities/default.json` 的 `opener:allow-open-url` 仅允许 `https://github.com/hawkeye-xb/P-Pass/releases/*`。桌面端网页侧调用 `openUrl` 打开上述地址会被 Tauri capability 拒绝。
3. `apps/desktop/src-tauri/capabilities/default.json` 属于 `.github/core-paths.txt` 核心路径（`+ apps/desktop/src-tauri/capabilities/**`），按流程须先合入已采纳方案再实施代码改动。

## 决定

在 `apps/desktop/src-tauri/capabilities/default.json` 的 `opener:allow-open-url` `allow` 列表中保留原有 `https://github.com/hawkeye-xb/P-Pass/releases/*`，并精确新增以下 4 条规则：

1. `https://p-pass.hawkeye-xb.com/*`（覆盖官网中英文首页 `/`、`/zh/`、常见问题 `/faq/`、`/zh/faq/`、隐私政策 `/privacy/`、`/zh/privacy/`）
2. `https://github.com/hawkeye-xb/P-Pass`（开源仓库主页）
3. `https://github.com/hawkeye-xb/P-Pass/discussions`（GitHub Discussions 问题反馈入口）
4. `mailto:ppass@hawkeye-xb.com`（问题反馈邮件客户端入口）

同步保持 `apps/desktop/src-tauri/src/lib.rs` 中 `webview_capabilities_are_least_privilege` 与 `update_failure_commands_are_registered` 的最小权限门禁不变（禁止 `opener:allow-default-urls` / `opener:default`），并补充测试校验 `capabilities/default.json` 覆盖上述「关于」外链。

## 理由

- **本质保证**：Webview 只能通过声明式白名单触发系统默认浏览器 / 邮件客户端打开受控的官方页面与反馈地址，防止被恶意链接利用打开任意 URL 或本地路径。
- **标准做法**：遵循 Tauri v2 Capability ACL 最小权限白名单（#1120 已在 `capabilities/default.json` 建立），逐条放行确定前缀/精确 URI，而非回退到通配 `opener:allow-default-urls`。

## 后果

- 桌面端「设置 → 关于」全部外链统一走前端 `openUrl(...)`，无需在 Rust 侧额外新增未受 ACL 约束的旁路命令或修改 `APP_COMMANDS`。
- 后续若在桌面端新增其他外部链接，仍需同步在 `capabilities/default.json` 登记并经核心路径评审。

## 备选

- **放开 `opener:allow-default-urls`**：不采纳。会撤回 #1120 建立的最小权限边界，使任意 `http://` / `https://` 都可从网页侧拉起。
- **在 `lib.rs` 新增自定义打开 URL 命令或导航拦截绕过 ACL**：不采纳。既违反 `command_lists_agree` 与最小权限边界，也造成跨权限模型割裂。
