# 适应度门禁：把产品理念变成「违反就红」

理念写在 AGENTS.md 里，会被忘；写成门禁，违反就红。本页说明每条检查保护哪条理念、怎么登记例外。
全部由 `just fitness-check` 跑（已挂进 `just ci`；远端是 `ci-rust.yml` 的 `fitness checks` job）。
每条检查都有自测 `tools/test-check-*.sh`：造违反必须红、还原必须绿。

## 总体规则

- 检查只看 git 跟踪的产品源码（`crates/`、`apps/`、`config/`），剔掉测试、生成物、注释；Rust 文件从 `#[cfg(test)]` 起截断。
- 登记表必须与现状**精确相等**：代码里有、表里没有 → 红；表里有、代码里已找不到 → 也红（删掉那一行）。
- 登记行的最后一段（用途 / 清理触发条件 / 说明）**不许为空**——写不出来就说明这一处不该存在。
- 登记表与检查脚本都在 `.github/core-paths.txt` 里：改它们要 `core review`，PR 里要写明为什么。

## 检查清单

| 检查 | 保护的理念 | 登记表 | 判据 |
|---|---|---|---|
| `tools/check-egress.py` | 红线 2「不做遥测」、隐私优先、尊重用户停掉的外联 | `tools/egress-allowlist.txt` | 网络出口文件（`site`）、外部主机名字面量（`host`）、网络类依赖（`dep`）必须登记用途；遥测 / 崩溃上报类 SDK（sentry、firebase、crashlytics、mixpanel…）一律红，**没有登记入口** |
| `tools/check-autostart.py` | 产品硬规矩「尊重用户停掉的服务」 | `tools/autostart-registry.txt` | 含自启 / 拉起 / 周期调度调用的文件必须登记 `guard:<符号>` 或 `test:<测试名>`，符号须仍存在 |
| `tools/check-disk-growth.py` | 产品硬规矩「占盘 1x」 | `tools/disk-growth-registry.txt` | 新增落盘目录（`.ppf/<名>`、`*_DIR` 常量或 `.join()` 里含 staging/cache/trash/quarantine/retired/superseded/blob/thumb 等）必须登记清理触发条件 |
| `tools/ios/gen-tokens.py --check` 等 | 品牌 tokens 以 `tokens.json` 与 Android 为准；iOS 偏离登记在 `platforms.ios` 并写 `why` | `assets/design/tokens.json` | 已有，在 `just mobile-static-check`：iOS token 逐字节比对；覆盖项必须指向存在的基础键并带 `why`；`check-no-color-literals.sh` 拦颜色字面量。桌面 `check-token-drift.py` 在 `just token-check` |
| `tools/ios/sync-i18n.sh --check` 等 | 桌面只改 i18n 副本；`assets/i18n` 与 Android / iOS 副本逐字节一致 | — | 已有，在 `just mobile-static-check`（iOS 副本）与其 `cmp`（Android 副本）；本页不重复实现 |

## 怎么登记例外

### 新增网络出口（`egress-allowlist.txt`）

格式：`site|<文件>|<用途>`、`host|<主机名>|<用途>`、`dep|<依赖名>|<用途>`。
先问：这个出口是功能必需吗？数据里有没有任何使用统计 / 设备标识之外的东西？
登记行和 PR 描述里都要写清**用途**与**发送的内容**。遥测类依赖不可登记，要改须产品负责人拍板（红线 2）。

### 新增自启 / 拉起点（`autostart-registry.txt`）

格式：`autostart|<文件>|guard:<函数或类型名>|<说明>` 或 `autostart|<文件>|test:<测试名>|<说明>`。
`guard:` 写调用前会先检查「用户停过」的判断（如 `user_stopped`、`AutoBackupPrefs`）；`test:` 写覆盖「用户停过不会被拉起」的 contract 测试名。
写不出来，就说明这处该改成先检查用户意图，而不是该登记。门禁只核对符号还存在，**守卫语义靠 review**。

### 新增落盘目录（`disk-growth-registry.txt`）

格式：`dir|<名字>|<清理触发条件>`（`.ppf/` 前缀不写）。
写明**谁、什么条件下清**（残留清扫类别、宽限、GC 周期），或为什么它不随照片数增长。
落盘目录的清理判据全文见 `docs/desktop/business-rules.zh-CN.md` §5.7。

## 做不到机器化、仍靠文字规矩与验收的

- **占盘 ≈ 1x 的实际量**：门禁只能挡「悄悄多出一个目录」，挡不了「已有目录里的文件只增不删」；写盘改动仍要 `du -sh` 实测（AGENTS.md）。手机端临时目录不在扫描范围内。
- **自启守卫的语义**：登记只证明符号存在，不证明守卫真的先于拉起被调用；靠 review 与 contract 测试。
- **出口里发送了什么**：静态扫描只看「有没有出口」，看不到载荷；载荷靠登记说明与 review。
- **读现状初始化、iOS 对齐 Android、界面文案**：需要判断，无法静态机检。
