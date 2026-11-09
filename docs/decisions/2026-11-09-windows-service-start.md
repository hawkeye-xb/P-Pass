# Windows 服务形态：「启动后台服务」必须真的启动

- 状态：已采纳
- 日期：2026-11-09
- 采纳：产品负责人 2026-11-09 在 owner 会话拍板选项 A
- 关联：#1582（回归发现与修复卡）、#1585 / #1590（服务启停纳入核心）、#1597（核心名单 ADR）

## 背景

0.11.1-test.3 Windows perMachine 安装，用户在设置中点「停止后台服务」，再在总览点「启动后台服务」：状态从 starting 一秒后变 stopped（reason=stopped outside），壳持续报 `连不上 ppf-svc：系统找不到指定的文件 (os error 2)`，手机端一直 loading。`sc query P-Pass` 显示服务存在、STOPPED、AUTO_START；手动 `sc start P-Pass` 能恢复，说明服务与二进制本身没问题。

根因在 `crates/platform/src/windows.rs` 的 `install_autostart` 服务形态分支：只检查服务已安装就 `return Ok(())`，不执行启动。壳的 `start_resident` 在用户显式点「启动」时正是调它来「请服务管理器起服务」；计划任务分支与 macOS 分支都会拉起，只有服务分支漏了这一步。`settle_after_start_action` 随后按事实把状态落成 stopped。

## 决定

采用 A，全部改动在 `crates/platform/` 内：

1. `crates/platform/src/windows.rs` 的 `install_autostart` 服务形态分支改为调用 `windows_service::start(SERVICE_NAME)` 并等待 RUNNING（最多 10 秒）；失败把错误返回给壳，不再静默 `Ok(())`。
2. 同一实现覆盖 `rewrite_autostart`：服务形态只返回 `Ok(())`，不改运行状态。对账只纠正登记内容，不负责拉起；只有用户显式点「启动」（或向导完成）才拉起。
3. `crates/platform/src/windows_service.rs` 增加 `start_and_wait`（复用 `start` 的幂等语义），把「等状态」抽成可注入状态序列的小函数，供单测覆盖 StartPending→Running、超时、服务消失三条路径。
4. 不改 `apps/desktop/src-tauri/src/lib.rs`，不把 Windows 专属分支放进壳层。

## 理由

**本质要保证什么**：用户显式点「启动」后，服务必须真的起来；起不来要如实报错，不能显示一个假装成功的 starting→stopped。服务起来才有 IPC 通道，手机才能连上、备份才能恢复。

**与现有机制对齐**：`install_autostart` 的契约是「登记并拉起」（macOS 的 launchd 登记会 RunAtLoad，计划任务分支会 `task.Run`）；服务形态漏了拉起，属于实现与契约不一致，不是新语义。`rewrite_autostart` 的存在正是为了把「对账只改登记」与「用户启动」分开；Windows 之前没覆盖它，是因为服务分支本来不拉起。补上拉起步后必须同时覆盖，否则启动对账会把「外面停掉的服务」顺手拉起来。

**偏离说明**：没有把 `lib.rs` 的 `start_resident` 改成分平台分支。那样也能修好，但把 Windows 专属判断放到平台层外，违反「平台分叉只许在 `crates/platform/`」，也会扩大 #1582 的范围。

## 后果

- 点「启动」在服务形态下真的 `sc start`，最多等 10 秒；服务起不来时 UI 报错，不再假装成功。
- 对账路径（启动时 `reconcile_autostart`）在服务形态不变运行状态：用户停过的服务不会被拉起；`distribution.rs` 的「登记缺失补登记」仍只在服务未安装（计划任务形态）时走到。
- 计划任务形态与 macOS 行为不变。
- 服务启动等待发生在壳的 `start_resident`（已在 `off_main` 的阻塞线程），不阻塞界面。

## 测试

- E2：`start_and_wait` 的等待逻辑用注入状态序列测三条路径（StartPending→Running / 超时 / 服务消失）；`install_autostart` 的服务分支抽成 `ensure_service_started(installed, start)`，单测断言 `installed=true` 必须调用 `start`，去掉调用即红。
- E3：Windows perMachine 真机，停止服务 → 点「启动后台服务」→ 60 秒内 `sc query` RUNNING、daemon 在线、手机可连、备份恢复；反证：旧构建同一路径仍 stopped（#1582 已记录）。
- E1：Windows 目标 `cargo check` + main 全量 CI（PR 上不跑 Windows）。

## 备选

- **B：在 `start_resident` 里按 `service_mode()` 分支调用 `restart_resident_daemon(false)`**。能修好，但把平台分叉放到 `apps/desktop/src-tauri/src/lib.rs`，违反「平台分叉只许在 `crates/platform/`」；还要把 `lib.rs` 加进 #1582 的范围。不采纳。
- **只在 `start_resident` 里额外调一次 `restart_resident_daemon`**：与服务分支的启动重复，且服务未安装时语义不对；不采纳。
- **让 `install_autostart` 服务分支只登记、由壳在用户点启动时另调 `restart_resident_daemon`**：等于 B 的变体，仍把平台行为分叉到壳，不采纳。
