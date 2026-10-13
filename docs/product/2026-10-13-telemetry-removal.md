# 决策记录：下线遥测上报，诊断只写本机日志（2026-10-13）

- 关联：[#949](https://github.com/hawkeye-xb/P-Pass/issues/949)（本次下线）、
  取代 [#146](https://github.com/hawkeye-xb/P-Pass/issues/146)（OBS-01）
- 读者：后续开发与代码审查。用来查证两件事：发布的 App 有没有上报过用户数据；
  上报代码现在还在不在。

下文每条事实都附了出处（文件路径 + 提交号）。仓库里查不到的内容没有写进来。

## 1. 遥测原来的样子

| 事实 | 出处 |
|---|---|
| daemon 客户端模块 `crates/daemon/src/telemetry.rs`：随机生成 `anon_id` 并存到 data_dir，事件攒批后每 300 s 用 HTTP POST 发出；`enabled = false` 时不发任何网络请求 | T-035 `853edf41`（2026-07-30） |
| 接收端是自建的 Cloudflare Worker，代码在 `infra/workers/telemetry/`，按事件类型写入 Cloudflare Analytics Engine | T-061 `1389e1ac`（2026-08-01） |
| 内置默认端点 `https://telemetry.p-pass.hawkeye-xb.com/ingest`（写在 `config/endpoints.default.toml`） | T-061b-fix `820f3fbd`（2026-08-03） |
| 开关的内置默认值：`[telemetry] enabled = true`（`endpoints.default.toml`），缺省兜底是 `unwrap_or(true)`（`crates/daemon/src/config.rs`）；可以用 config.toml 或环境变量关闭 | T-004 `23c39117`（2026-07-28） |
| 事件字典 v2 共五类：`conn` / `flow_item` / `first_byte` / `daemon_alive` / `error`，每条都带 `anon_id` / `ver` / `ts` | `cards/done/OBS-02-telemetry-event-dictionary-usefulness-review.md`；TEL-01 `8ed5179e` |
| 接线：`conn` / `flow_item` 接在 FlowDelivery 上，`first_byte` 接在 QueryEngine 上，`error` 做了细分码和去重，HTTP 总超时 20 s，队列上限 500 | TEL-02 `517240db`、TEL-04 `30d818eb`、TEL-03 `0c2d86c7`、TEL-05 `413f9d12`；卡片见 `cards/done/TEL-0{1..5}-*.md` |

## 2. 实际开启过的范围

**结论：发布的桌面 App 与 Android App 从未开启上报**（按正常安装与使用流程；仓库里能
找到的边缘例外见 2.5）。**裸跑 daemon（不带 config，或 config 缺
`[telemetry]` 段）默认会上报。**

本 PR 合入后下面引用的代码就不存在了。行号统一以删除前的 main（`ba4e3132`）为准，
用 `git show ba4e3132:<路径>` 可以复现，例如
`git show ba4e3132:apps/desktop/src-tauri/src/lib.rs | sed -n 386,401p`。

### 2.1 桌面 App 写的是 `enabled = false`

- `apps/desktop/src-tauri/src/lib.rs:386` `fn render_config`，`:398-399` 写出
  `[telemetry]` / `enabled = false`（@`ba4e3132`）。首启向导经
  `:417` `write_first_run_config` 把它写进平台目录的 `config.toml`。
- 首次引入：T-042 `8511f4e7`（2026-07-31），当时由 `write_config` 用 `format!` 写出同样的
  `[telemetry]\nenabled = false`（`git show 8511f4e7 -- apps/desktop/src-tauri/src/lib.rs`）。
- 之后桌面代码里这个值没有改过：`git log -S"enabled = false" -- apps/desktop/src-tauri/src/lib.rs`
  只命中 `8511f4e7`，以及 `64a25b58`、`b625fde9` 两次测试改动。
- 有没有 config 决定走不走向导：`apps/desktop/src-tauri/src/lib.rs:202`
  `"configured": dir.join("config.toml").exists()`（@`ba4e3132`）。正常使用时，
  daemon 读到的 config 源自向导写入。

### 2.2 最早的发布版本晚于 `8511f4e7`

```
$ git tag --no-contains 8511f4e7
m0-complete
$ gh release list --limit 300 --json tagName,createdAt --jq 'sort_by(.createdAt) | .[0] | "\(.tagName) \(.createdAt)"'
test-channel 2026-09-30T05:48:52Z
```

`m0-complete` 是唯一不含 `8511f4e7` 的 tag，指向 `9886a46f`（2026-07-25）。它早于遥测
客户端 T-035 `853edf41`（2026-07-30），并且 `git ls-tree -r m0-complete --name-only | grep -c apps/desktop`
的结果是 0，不包含桌面 App。

### 2.3 Android / iOS 没有遥测客户端

```
$ git grep -c -i -E "telemetry|analytics|crashlytics|firebase|sentry" ba4e3132 -- apps/android apps/ios
（无输出，exit=1，0 命中）
```

历史上也没有：`git log --all -i -S"telemetry" -- apps/android apps/ios` 只命中
`30e1dc7f`、`fba35e2a`、`6a183644`。这三处都是 Android 源码注释里提到 daemon 的
错误码，后来已经删掉，不是上报代码。

### 2.4 裸跑 daemon 默认上报，关闭时零网络

- 内置默认值：`config/endpoints.default.toml:17-18` 是 `[telemetry]` / `enabled = true`，
  `:22` 是 `url = "https://telemetry.p-pass.hawkeye-xb.com/ingest"`（@`ba4e3132`；
  `enabled = true` 由 T-004 `23c39117` 引入，url 由 T-061b-fix `820f3fbd` 定稿）。
- 缺省兜底：`crates/daemon/src/config.rs:72` `enabled: telemetry.enabled.unwrap_or(true)`；
  `:148` 是环境变量覆盖入口（@`ba4e3132`，T-004 `23c39117`）。
- 开关关闭时整条上报任务不启动：`crates/daemon/src/main.rs:513-521`。注释写的是
  "opt-out respected at the root"，`:520` `if telemetry.enabled()` 为真才在 `:521`
  `tokio::spawn(telemetry.clone().run())`（@`ba4e3132`）。
- 「关闭 = 零网络」契约在 `crates/daemon/src/telemetry.rs`（@`ba4e3132`）：
  - `:5` 模块文档写明 "`enabled = false` means ZERO network calls"；
  - `:176` `record` 在入口处丢弃事件，`:212` `flush_now` 直接返回 0，`:240-241` `run` 直接返回。
- 对应测试（@`ba4e3132`）：
  - `crates/daemon/tests/telemetry_flow.rs:138` `disabled_switch_means_zero_requests`；
  - `crates/daemon/src/telemetry.rs:329` `disabled_never_mints_an_anon_id`；
  - `crates/daemon/tests/flow_delivery.rs:873` `disabled_telemetry_means_zero_network_calls_from_flow_delivery`；
  - `crates/daemon/tests/query_telemetry.rs:157` `disabled_telemetry_means_zero_network_calls_from_query_engine`。
- 狗粮部署显式关闭：`docs/dogfood-deploy.md:63` `PPF_TELEMETRY_ENABLED=false \`
  （@`ba4e3132`）。从手册最初版本 `80b0835c` 起就有这一行。
- **开发期裸跑 daemon 有没有产生过数据，仓库无法核实**，要看线上 Analytics Engine，
  见 [#950](https://github.com/hawkeye-xb/P-Pass/issues/950)。

### 2.5 已知边缘例外

「改库位置」时改写 config 的代码，在读 config 失败（权限、非 UTF-8）时都会把它当成空文件，
写回的文件只剩 `data_dir`、没有 `[telemetry]` 段。如果被改写的正好是 daemon 读取的那份
config，daemon 下次启动就会回到默认开启。仓库里有两处这样的写法：

- daemon 侧的 `write_folder_config`，由 T-034 `12f8e233`（2026-07-30）引入：
  `crates/daemon/src/ipc.rs:303`（@`12f8e233`）`read_to_string(&config_path).unwrap_or_default()`。
  它写的是 `self.data_dir.join("config.toml")`，DESK-46 `64a25b58` 删掉了它（该提交称之为
  「孤儿 config.toml」）。各个版本里这个路径和 daemon 实际读取的 config 是否是同一份，
  仓库里无法逐版核实。
- 桌面侧的换库，由 DESK-46 `64a25b58`（2026-10-04）引入：
  `apps/desktop/src-tauri/src/lib.rs:431`（@`64a25b58`）同样是 `unwrap_or_default()`。
  DESK-49 `b625fde9`（2026-10-08）修好了读失败的处理。

这条边缘路径确切存在的时间窗、有没有用户触发过，仓库都无法核实。

## 3. 为什么下线

- 对排查问题没有价值：真实用户（桌面向导写入 `enabled = false`、移动端没有客户端）
  基本不产生数据，云端收不到能用的样本。
- 和产品的隐私定位冲突：上报代码留在里面，内置默认值又是开启，本身就是隐私风险。
- 对外说法和代码对不上：官网隐私页原来写的是「代码中包含匿名统计功能，默认关闭」，
  而 daemon 的内置默认值是开启。

## 4. 替代方案

- 原来的 `conn` / `flow_item` / `first_byte` / `daemon_alive` 改成写本地 `tracing`
  日志，target 为 `ppf::stats`，级别 info（`crates/daemon/src/stats.rs`）。日志落进
  daemon 现有的日志文件，也就是桌面端「导出日志」导出的那一份。是否导出、是否发给
  我们，由用户自己决定。
- 原来的 `error` 事件不再单独记录，因为每个失败点已经有带原因的 `warn!` 日志：
  `crates/daemon/src/router.rs` 的 Flow 处理（offer / fetch / cancel、cancel_tuple），
  以及 `crates/daemon/src/flow_delivery.rs` 的后台拉取失败与 `flow.failed push ... detail=` 行。
- 不再生成 `anon_id`，不发任何网络请求，daemon 也不再依赖 `reqwest`。

## 5. 遗留项

- 线上接收端 Worker 和 DNS 的删除另开卡处理：
  [#950](https://github.com/hawkeye-xb/P-Pass/issues/950)。
- 旧 config 里的 `[telemetry]` 段（已安装的桌面用户都有）为了兼容而保留：daemon
  读到后忽略，不会因为 unknown field 拒绝启动（`crates/daemon/src/config.rs` 的
  `_legacy_telemetry` 字段和 `legacy_telemetry_section_is_accepted_and_ignored` 测试）。
  桌面端换库时会逐字节保留这一段，不会主动删除。
- 老用户 data_dir 里可能还留着 `anon_id` 文件，现在没有任何代码读取它；daemon 启动时会尽力把它删掉（`crates/daemon/src/stats.rs` 的 `purge_legacy_anon_id`，文件不存在静默，删除失败只记 warn、不影响启动）。

## 6. 以后的规则

如果以后有人想加回任何形式的使用统计或上报，必须先开 issue，由产品拍板。
不能作为顺手改动混进别的 PR。这条规则也写进了 `AGENTS.md` 红线第 2 条。
