# DEVLOG-01 开发期前台起的 daemon 日志只在终端一闪而过，出问题时没有日志可查

> ✅ 状态：代码已合并（见「实施记录」commit），2026-09-17 归档
> 级别：L3（开发期工具；`PPF_LOG_FILE` 不设时生产路径一行未变）· 阻塞：无

## 问题

生产 daemon 由 launchd 托管，日志靠 plist 的 `StandardOutPath` /
`StandardErrorPath` 落盘，出问题时日志**已经在**那儿。

开发期手动前台起 daemon 没有 launchd 托管，日志只写 stderr、只在终端存在：
终端关了、滚出屏幕、或者 daemon 是被某个脚本拉起来的，日志就没了。于是排障
只能"复现时临时开一次日志重来一遍"，而不是"出问题时日志已经在"——对偶发
问题（NET-01 那类跨网络抖动、MOB-85 那类系统策略杀进程）等于没有日志。

本模块（`log_guard.rs`）已经有一套 NET-02 建立的折叠 + 体积上限逻辑，但它
被写死成只能写 stderr（`BoundedStderr` + fd 2 的 truncate 技巧）。

## 期望行为

同一套折叠 + 上限逻辑能接到一个持久文件上，由环境变量显式启用；不设环境
变量时行为与改动前逐字节一致（只写 stderr，生产 launchd 路径不受影响）。

## 验收标准

- [x] `PPF_LOG_FILE=<path>` 起 daemon → 该路径出现真实日志文件，父目录不
      存在时自动创建
- [x] 不设 `PPF_LOG_FILE` 起 daemon → 行为与改动前一致，日志照旧写 stderr
- [x] `PPF_LOG_FILE` 指向打不开的路径 → 报错退出（exit 2），**不静默退回
      stderr**（照 DAE-03「绝不静默忽略」先例：用户显式指定了日志文件，
      悄悄退回等于让他以为日志在写而其实没有）
- [x] 文件 sink 吃同一个折叠逻辑与同一个容量上限，不会无界增长
- [x] 反证：禁掉容量上限判据后，截断用例必须变红

## 范围

- 只准动：`crates/daemon/src/log_guard.rs`、`crates/daemon/src/main.rs`
- 不准动：launchd plist 与生产日志路径；DESK-10 的导出包组装逻辑；
  `truncate_stderr` 的 fd 2 技巧（那是 NET-02 的既有资产）

## 阻塞与依赖

无。

---

## 实施记录

**来源**：本卡的代码是从一个外部 worktree（`devlog/persistent-local-logs`
分支）收口回 main 的。该 worktree 落后 main 8 个提交、零独有提交，
`log_guard.rs` 有 184 行未提交改动且**没有对应的卡**——属于账外工作。
2026-09-17 状态对齐时发现并按本卡收口。

**收口时补的三处**（原改动不完整，不是原样合入）：

1. **接线**。原改动加了 `DedupGuard::for_file()` 与
   `persistent_log_path_from_env()`，但 `main.rs:46` 仍是
   `DedupGuard::new()`——两个新函数生产零调用，是死代码。原注释自己写着
   "main 用它决定要不要调用 `DedupGuard::for_file`"，接线是补完它已声明
   的范围。打不开路径的分支照 `parse_cli` 的先例做 `eprintln!` + `exit(2)`。
2. **格式化**。原改动未过 `cargo fmt`（`log_guard.rs:402` 一处），直接
   push 会重演 8/7 的 fmt 红。
3. **修死循环测试**。原 `file_sink_truncates_past_the_cap` 写成
   `while *written < SINK_CAP_BYTES { ... }`，而 `write_line` 是在跨过
   上限**之前**就 truncate 并把计数器重置成 marker 长度的——该条件恒真，
   测试永不退出（实测跑满 60s 后被 SIGKILL）。说明这条测试从未被它的
   作者跑过。改成固定行数上界（`SINK_CAP_BYTES / 行长 + 2`），并把
   chunk 从 1KB 放大到 1MB，用例从死循环变成 0.35s。

**测试**：

```
cargo test -p daemon --lib log_guard::
  → 7 passed; 0 failed（0.31s）
```

**反证**（真跑，已还原）：把 `write_line` 的上限判据改成恒假
（`if false && ...`）后：

```
panicked at crates/daemon/src/log_guard.rs:413:
  byte counter must reset after truncation, got 10486230
test result: FAILED. 0 passed; 1 failed
```

**端到端验证**（隔离 `HOME` 到临时目录，全程未接触生产库；验证期间生产
daemon PID 86519 正常存活）：

| 分支 | 命令 | 结果 |
|---|---|---|
| 设了 | `HOME=<tmp> PPF_LOG_FILE=<tmp>/logs/dev.log daemon --ephemeral` | exit 0；`logs/` 自动创建，`dev.log` 377 字节真实日志（relay/stdin/SYNC-01 三行）；终端 stderr **0 行** |
| 不设 | `HOME=<tmp> daemon --ephemeral` | exit 0；stderr 4 行，与改动前一致 |
| 打不开 | `PPF_LOG_FILE=/dev/null/nope/dev.log` | **exit 2**；`PPF_LOG_FILE=/dev/null/nope/dev.log 打不开：Not a directory (os error 20)` |

## 备注

- **这是 either/or，不是 tee**：设了 `PPF_LOG_FILE` 就**不再写 stderr**，
  前台跑 daemon 时终端会变哑。`with_writer` 只吃一个 writer，原设计如此，
  收口时按原设计实现、没有自行改成 tee。要终端同时有输出就别设这个变量。
- **与 DESK-10 零交互**（已核实，非推测）：导出包是桌面壳
  `apps/desktop/src-tauri/src/daemon_logs.rs` 组装的，日志路径**从 launchd
  plist 的 `StandardOutPath`/`StandardErrorPath` 读出来**，不扫目录、不认
  环境变量；生产也不设 `PPF_LOG_FILE`，文件根本不存在。
  ⚠️ 反过来说：**生产环境永远不要设 `PPF_LOG_FILE`**——那会让 stderr 变哑，
  plist 指的 `.err` 变空，DESK-10 的导出包随之失去它最重要的那个文件。
- **父卡 NET-02**（`cards/done/NET-02-relay-handshake-failures-write-73mb-of-stderr.md`）：
  本卡泛化的就是它建立的折叠 + 上限逻辑。`BoundedStderr → BoundedSink` 这次
  重构**真的碰了生产 stderr 路径**，不能因为本卡是 L3 就一笔带过——生产路径
  由 NET-02 的既有用例兜底，四条全绿（`fold_key_*` 2 条、
  `a_single_occurrence_*`、`a_burst_prints_first_line_then_exactly_one_summary`）。
- Windows 上 `truncate_stderr` 仍是 no-op（NET-02 的已知缺口，未动）；文件
  sink 走 `set_len(0)`，跨平台都真的生效。
