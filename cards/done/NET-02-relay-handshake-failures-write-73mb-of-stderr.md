# NET-02 relay 握手失败把 stderr 写到 73MB（L2）

**状态**：✅ 已完成（2026-08-26 家中真机取证实锤；2026-08-27 修复+验收，见文末验收记录）

## 证据

家中 Mac，`~/Library/Logs/p-pass-daemon.err`：

- **73 MB / 24.7 万行**
- 其中 `tls handshake eof` **92211 行**
- 集中在 8/26 22:22–22:29 的 **7 分钟**内

7 分钟写 9 万行 ≈ **每秒 220 行**。

触发条件：验收人家里的 Clash（mihomo）把 iroh relay 的流量走了代理，relay
的 TLS 握手在代理上失败。他给 relay 域名/IP 加了直连白名单后立即恢复
（22:29 配对成功，之后传了 13 张；8/27 全天 relay 错误 = 0）。

## 缺陷是什么

**不是"relay 连不上"**——那是用户的代理配置，我们管不着，而且失败重试本身
是对的。缺陷是**失败被无节流地写进 stderr**：

- 磁盘：7 分钟 73MB。持续一晚就是 GB 级
- IO：每秒 220 行同步写，和备份传输抢 IO
- **可诊断性反而变差**：73MB 里 92211 行是同一句话，真正有用的行被埋了。
  取证时必须靠 `grep -c` 才能读——这已经是 DESK-10（导出日志漏掉唯一有用的
  日志）的近亲

## 期望行为

同一类错误在窗口内折叠计数，而不是逐次打印：

- 相同 error kind 在 N 秒窗口内只打第一条 + 结束时打一条汇总
  （`tls handshake eof ×92211 in 7m4s`）
- **一条都不许丢语义**：汇总行必须带次数和时长，否则排查时无法判断严重度
- stderr 上限（rotate 或 truncate），不许让一个循环失败吃满磁盘

## 验收标准

- [ ] 构造 relay 不可达（防火墙 drop relay IP / 指一个死 relay URL），跑
      10 分钟 → `.err` 增量 < 1 MB
- [ ] 折叠后的日志里**仍能看出**失败类型、首次时间、次数、持续时长
- [ ] 单次失败（非循环）的日志行为不变——不许为了折叠把偶发错误也吞掉
- [ ] `.err` 有体积上限，超限行为明确（rotate/truncate 二选一，写进注释）

## 范围

daemon 的 tracing/日志初始化 + transport 层 relay 重连的错误路径。

**不准动**：重连策略本身（重试是对的，本卡只管日志量）。

## 与其他卡的关系

- **DESK-10**（导出日志漏掉唯一有用的日志）：同一个主题的另一面。DESK-10 是
  "该收的没收"，本卡是"收了但被噪音淹了"。两张卡都修完，诊断包才真的可用。
- **NET-01**（backup begin 超时 15s 后退避）：同一晚同一条链的上游现象。

## 备注：这次故障里代理是**前半段**的根因

8/26 22:22–22:29 传不动 = relay 走代理握手失败（本卡的现场）。加直连后立即
恢复并传了 13 张。**22:36 之后不传是另一件事**，与代理无关——见
`docs/evidence/2026-08-26-home-partial-upload.md`。

---

## 验收记录（2026-08-27）

**实现**：新增 `crates/daemon/src/log_guard.rs::DedupGuard`（实现
`tracing_subscriber::fmt::MakeWriter`），接入 `main.rs` 的 `tracing_subscriber`
初始化，替换裸 `std::io::stderr`：
- 折叠 key = 格式化后整行去掉行首时间戳（唯一每次都变的部分）——第一次
  出现立即打印；后续完全相同的重复只计数，安静 2 秒（`IDLE_GAP`）后打一条
  汇总（`{原文本} (折叠 ×{count} over {duration})`）并清空该 key；单次/偶发
  失败只走"打第一条"，不会补发多余的 `×1` 汇总。
- 独立的 8MB/次运行硬上限（`BoundedStderr`）：折叠按精确文本分组，如果某
  个循环 bug 每次内容都不完全一样（比如带自增计数器）会漏网，这道背景防
  线保证即使折叠没接住，一次运行也写不爆磁盘——超限就地 `ftruncate`
  当前 stderr 文件（Unix；fd 2 就是 launchd/systemd dup2 过去的那个文件，
  直接 truncate+seek 就是缩小它本身）。Windows 分支老实标注"还没接、
  已知缺口"，没有装作修好。
- 顺带 `.with_ansi(false)`：落盘的 `.err` 不需要终端颜色码，也让折叠 key
  的提取不必绕过 ANSI 转义序列。

**验证**：
- 单测 4 个（`cargo test -p daemon --lib log_guard`）：`fold_key` 时间戳
  剥离的两个纯函数测试；`a_single_occurrence_prints_once_and_never_gets_a_summary`
  （偶发失败行为不变）；`a_burst_prints_first_line_then_exactly_one_summary`
  （**真实复现 92211 次重复**，虚拟时钟驱动，断言最终折叠掉的总字节数
  远小于原始洪水的十分之一行）。调试中踩了一个坑：最初用
  `std::time::Instant` 记录时间，`tokio::time::advance`/`sleep` 只拨动
  tokio 自己的虚拟时钟，`std::time::Instant::now()` 不受影响，导致"是否
  已安静"的判断永远读到真实墙钟时间（几微秒），从未触发——改用
  `tokio::time::Instant` 后测试才真正验证了折叠逻辑，而不是碰巧通过。
- `just ci`（fmt + clippy -D warnings + nextest 全量 + arch-check +
  queue-check）全绿，退出码 0。
- **真机二进制验证**：编译 `target/debug/daemon`，起一个本地假 relay
  （accept 后立即 close，模拟 8/26 那晚 Clash 代理导致 TLS 握手 EOF 的
  效果），`PPF_DATA_DIR`/`PPF_RELAY_URLS` 指向隔离的 scratch 目录（不碰
  真实用户数据）跑了约 95 秒。观察：daemon 的网络质量探测
  （`net_report::reportgen`）每 ~21 秒一轮、失败打 3 行 WARN，95 秒内总共
  25 行/9KB，线性增长、无洪水；两种探测失败文本每轮都各自"打第一条"
  （两轮间隔 > 2 秒 idle_gap，折叠状态每轮清空重来）——**这实测验证了
  "单次/偶发失败不受影响"这条验收标准在真实二进制下也成立**，不只是
  合成单测。
  **已知局限**：这次没有复现到故障当晚真正的紧密循环（220 行/秒、
  92211 行/7 分钟）——那个循环发生在**已配对设备正在通过 relay 传输**
  时的连接维持重试上，跟这里"daemon 独自跑、被动网络探测"不是同一条
  代码路径；要复现需要第二台设备/testclient 真的在传输，本次验收未做
  （若后续需要，可另起一张卡补一个双端集成复现）。折叠机制本身的洪水
  级压力测试已由上面的单测（真实 92211 次重复）覆盖。
- 没有把这个验证脚本（假 relay + 真二进制 + sleep）写进 CI：它测的其实
  是 iroh 库自己的探测退避节奏而不是我们的代码，慢且环境敏感，价值已被
  更快更确定的单测覆盖——留作手动验证过，不是回归门禁。

**范围核对**：只改了 daemon 的 tracing 初始化（`main.rs`）+ 新增
`log_guard.rs`；没有动 transport 层的 relay 重连策略本身，符合卡片
"不准动"的限制。
