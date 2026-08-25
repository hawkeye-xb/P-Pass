# DESK-10 「导出日志」不含 daemon 日志，且 daemon 挂了它自己也不工作　级别 L1

> 🟡 代码已合并（commit 1e1359f），等真机验收
> 级别：L1 · 阻塞：无

## 问题

设置页的「导出日志」产出 `ppf-logs.zip`，里面**只有两个文件**
（`crates/daemon/src/ipc.rs:1129` `export_logs()`）：

- `diag_events.json` — 数据库里的 diag 事件（上限 1000）
- `devices.json` — 设备白名单

**不含**任何真正能查启动/崩溃问题的东西：

- `~/Library/Logs/p-pass-daemon.err` ← daemon 起不来的真实原因**只在这里**
- `~/Library/Logs/p-pass-daemon.log` ← NodeId / 库目录 / 配对串
- 配置（`data_dir` / `bind_addr`）
- 应用与 daemon 的版本号
- 审计日志（`audit.list` 已有 IPC，没进包）

### 更致命的一条：它是 daemon 的 IPC 方法

`export_logs` 挂在 `logs.export` 这个 IPC 上，**daemon 起不来时这个按钮
压根不工作**——而 daemon 起不来正是最需要日志的场景。

### 真实事故（2026-08-25，验收人）

daemon 因版本降级（旧包打开新库的索引）反复启动失败，界面只说「后台服务
没有在 10 秒内就绪」（另见 `DESK-09`）。验收人按「导出日志」把 zip 发过来
求助，**包里只有 1 条 2026-08-21 的旧 diag 事件，489 字节**，对定位这次故障
零帮助。真实错误（`migration 2 was previously applied but is missing in the
resolved migrations`）一直躺在 `~/Library/Logs/p-pass-daemon.err` 里，重复
了 8 次，没人收。

验收人原话：「那他妈的导出的 log 有啥用？！让用户给你扔一个没用的东西？」

## 期望行为

- 包里必须有 daemon 的 stdout/stderr 日志（LaunchAgent 的
  `StandardOutPath` / `StandardErrorPath` 指的那两个文件，路径从 plist 读，
  不硬编码）。
- 必须有版本号（App + daemon）与配置摘要（`data_dir` / `bind_addr`，
  路径照现有 `sanitize()` 脱敏）。
- **daemon 挂着也要能导出**：导出走桌面壳本地文件读取，不依赖 daemon IPC。
  daemon 活着时再附加它能提供的部分（diag/devices/audit）；daemon 不可达
  时包里放一份 `daemon-unreachable.txt` 说明，其余照常收集。
- 包里带一个 `README.txt`：这些文件分别是什么、遇到问题先看哪个。

## 验收标准

- [x] 集成：daemon **不可达**时点导出 → 仍产出 zip，且含 daemon 的
  `.err` / `.log` 与版本信息
- [x] 反证：把「不依赖 IPC」这条改回走 daemon → 上一条变红
- [x] 集成：daemon 正常时导出 → 上述文件 + diag/devices/audit 都在
- [x] 复现本卡那次事故：让 daemon 因迁移不兼容启动失败 → 导出的包里
  **必须**出现 `migration ... missing in the resolved migrations` 这行
  （本机以 tempdir 造出同样内容的 `.err` 验证；真机复现见「还差什么」）
- [x] 脱敏不回退：家目录路径仍走 `sanitize()`，NodeId 仍只出前缀
  （现有行为，不许因为加文件而漏掉新加的那些）

## 范围

- 只准动：`crates/daemon/src/ipc.rs` 的 `export_logs`（daemon 活着时那部分）、
  桌面壳的导出入口与本地文件收集、相关测试
- 不准动：脱敏函数的语义；`ppf-logs.zip` 这个文件名与落盘位置（验收人已经
  习惯了）

## 阻塞与依赖

无。与 `DESK-09`（向导吞掉 daemon 真实错误）是同一场事故的两面，可一起做：
`DESK-09` 让错误**当场可见**，本卡让错误**可被带走**。

---

## 备注

Windows/Linux 的日志位置不同（LaunchAgent 是 macOS 专属）。实施时按平台
取：macOS 从 plist 的 `StandardErrorPath` 读；其它平台待 daemon 常驻方案
落地后再定，本卡先把 macOS 这条做对，不为未定的平台预留抽象。

---

## 实施记录（1e1359f）

### 改了什么

- `apps/desktop/src-tauri/src/lib.rs`——新命令 `export_logs_bundle`（**桌面壳
  本地组装**，daemon IPC 只是可选补充）。收集与落盘拆成 `assemble_export`，
  daemon 那部分以 `Result<DaemonParts, String>` 传进去：**Err 不是失败路径**，
  只是少三份文件、多一份 `daemon-unreachable.txt`，zip 照出。
- `apps/desktop/src-tauri/src/daemon_logs.rs`（新，与 `DESK-09` 共用）——
  plist 解析取日志路径、tail、脱敏（`sanitize` + 长 hex 掩码）、`build_bundle`
  纯函数、zip 读写。
- `apps/desktop/src/App.svelte`——「导出日志」从 `call("logs.export")` 改成
  `invoke("export_logs_bundle")`。
- `crates/daemon/src/ipc.rs`——`export_logs` 补 `audit.json`（`actor` 只出
  前 4 字节前缀，`detail` 过 `sanitize()`）。

### 包里现在有什么

| 文件 | 内容 |
|---|---|
| `README.txt` | 每个文件是什么、遇到问题先看哪个 |
| `daemon-stderr.log` / `daemon-stdout.log` | plist 的 `StandardErrorPath` / `StandardOutPath` 指的那两个文件，取尾部 256 KiB |
| `versions.txt` | App 版本 + daemon 版本 + daemon 是否可达 + 平台 |
| `config-summary.txt` | `data_dir` / `bind_addr`（路径脱敏） |
| `log-sources.txt` | plist 是否注册、两个日志路径的实际取值（脱敏） |
| `daemon-unreachable.txt` | 仅 daemon 不可达时出现，写清为什么连不上、以及缺了哪三份 |
| `diag_events.json` / `devices.json` / `audit.json` | 仅 daemon 可达时附加（daemon 侧已脱敏，原样搬进同一个包） |

落盘位置与文件名不变：`<库目录>/ppf-logs.zip`。

### 三个实施要点

1. **daemon 版本在 daemon 挂着时也要有** —— 直接问内置的服务程序
   `ppf-daemon --version`（那次事故里正是这一句话拿到了真相）。取不到 →
   写 `(读不到)`，绝不因此让导出失败。
2. **不硬编码日志路径** —— 只认 plist 的 `StandardOutPath` /
   `StandardErrorPath`；plist 不存在就在 `log-sources.txt` 里写「未注册」，
   不去猜 `~/Library/Logs`。
3. **先读后写** —— daemon 可达时它自己那份 zip 与我们要写的是同一个
   `ppf-logs.zip`，所以先把它的条目整份读进内存，之后才允许覆盖。

### 脱敏口径

- 家目录 → `<DATA>`（与 daemon 侧 `sanitize()` 同语义；桌面壳是独立
  workspace，不依赖业务 crate，所以是同语义的第二份实现）。
- 长 hex 串（NodeId 全长 64、配对令牌 24）只留前 8 位 + `…<masked>`——
  daemon 的 stdout 日志里有 NodeId 和配对串，口径必须跟 `devices.json`
  一致。短 hex（端口号之类）不动。
- **新加的文件全过同一道 scrub**，测试断言「包里不许出现真实家目录」。

### 证据

`cd apps/desktop/src-tauri && cargo test --lib`：

```
test tests::export_bundles_logs_even_when_the_daemon_is_unreachable ... ok
test tests::export_adds_daemon_parts_when_reachable ... ok
test result: ok. 17 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

不可达那条测的是真落盘：tempdir 造假 plist + 假 `.err`（内容就是那次事故的
8 次重复）+ 假 config → 调 `assemble_export` → 打开真的 zip 断言条目名、
断言包里含 `migration 2 was previously applied but is missing in the resolved
migrations`、含 App 与 daemon 版本、**不含**家目录路径且含 `<DATA>`。

daemon 侧（`just ci`，nextest 全仓）：

```
Summary [  11.179s] 319 tests run: 319 passed, 1 skipped
```

其中新增 `logs_export_zip_carries_audit_events`（`audit.json` 在包里、含
`device.revoked`、`actor_prefix` 只有前 4 字节、全长 NodeId 不在包里）；原有
`logs_export_zip_leaks_no_username` 仍绿（脱敏没回退）。

`cd apps/desktop && pnpm test`：`Test Files 4 passed / Tests 31 passed`；
`pnpm build`：`✓ 208 modules transformed`。

### 反证（真跑，红输出摘录）

把 `assemble_export` 里 daemon 不可达的分支改成 `return Err(reason)`
（= 退回「走 daemon IPC」的老行为）：

```
running 17 tests
test tests::export_bundles_logs_even_when_the_daemon_is_unreachable ... FAILED

---- tests::export_bundles_logs_even_when_the_daemon_is_unreachable stdout ----
thread panicked at src/lib.rs:641:10:
daemon 不可达也必须出包: "找不到运行中的 P-Pass 后台服务（ipc.token 不存在）"
```

改回后 17 passed。

### 还差什么（真机）

1. daemon 正常在跑时点「导出日志」→ 解开 zip，上表 9 个文件都在，且
   `daemon-stderr.log` 是真日志内容、`versions.txt` 两个版本号都对得上。
2. 让 daemon 真的因迁移不兼容启动失败（旧版本包 + 新版库）→ 点「导出日志」
   → 包里出现 `migration ... missing in the resolved migrations`，且有
   `daemon-unreachable.txt`。
3. 抽查脱敏：`grep` 整个 zip，不许出现你的用户名。
