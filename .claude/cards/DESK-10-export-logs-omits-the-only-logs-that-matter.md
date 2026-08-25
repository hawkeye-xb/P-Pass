# DESK-10 「导出日志」不含 daemon 日志，且 daemon 挂了它自己也不工作　级别 L1

> ⬜ 状态：未开工
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

- [ ] 集成：daemon **不可达**时点导出 → 仍产出 zip，且含 daemon 的
  `.err` / `.log` 与版本信息
- [ ] 反证：把「不依赖 IPC」这条改回走 daemon → 上一条变红
- [ ] 集成：daemon 正常时导出 → 上述文件 + diag/devices/audit 都在
- [ ] 复现本卡那次事故：让 daemon 因迁移不兼容启动失败 → 导出的包里
  **必须**出现 `migration ... missing in the resolved migrations` 这行
- [ ] 脱敏不回退：家目录路径仍走 `sanitize()`，NodeId 仍只出前缀
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
