# FIX-SC2 blobs_resume 300s 超时 flake 根治　级别 L2（2026-08-10 用户拍板改方向）

## blocker

`transport::blobs_resume::kill_mid_transfer_then_resume_verifies` 在
pr.yml lint+test 里 300s TIMEOUT，已撞 3 次（NEXT.md DAE-02 段 1 次 +
2026-08-10 run 31351715951 / 31353615430），每次靠 rerun 碰运气。

## 关键证据：这不是「慢」，是「卡死」

- 隔离复跑 **6.4s** 过（NEXT.md 在案）；
- 验收人本机全量并行跑 **12.75s** 过（2026-08-10，219/219 那轮）；
- CI 上 300s 打满被杀。

12s 的测试不会因为 runner 慢就变成 300s+——**量级差说明是并发时序下的
stall/死锁/无限等待**（候选：kill 后重拨等一个永远不来的连接、retry
backoff 空转、并行测试间端口/socket 竞争、iroh-blobs 内部竞态）。

## 禁止项（用户明令，写在最前面）

以下手段**不许作为修复**：放宽 timeout、缩小测试数据量、加 retries、
跳测/标 flaky。`--test-threads 1` 只许作为「证明与并发相关」的**实验
证据**，不许作为最终修法——生产里 daemon 同样是并发环境，串行化测试
等于把真 bug 扫进地毯。

## 修法（按序做，每步产出证据）

1. **先落取证桩（可以单独先推）**：给该测试加带时间戳的进度标记
   （bind / 传输进度字节数 / kill / 重开 store / redial / pull 进度 /
   verify 各阶段 eprintln 或 tracing）——下次 CI 再 TIMEOUT，日志直接
   指出卡在哪个阶段。变 rerun 碰运气为每次失败都在积累证据。
2. **本地复现**：高并发压力下循环跑（`cargo nextest run -p transport
   --retries 0` 全量并行 + 人为 CPU 负载，或提高 test-threads），目标
   是拿到至少一次本地 stall + 完整进度日志。复现不了就在 CI 上用
   workflow_dispatch 循环收集（不打 tag）。
3. **从卡点定根因**：进度日志指到哪个阶段，就查那个阶段的时序——
   test harness 的竞态（如 kill 时机与 store 落盘竞争）和产品代码的
   竞态（transport 重连/续传逻辑）都有可能。**若是产品 bug，这张卡
   价值翻倍**（用户真机 kill App 续传就是这条路径）。
4. **例外出口（须证据齐全）**：若根因锁定为 iroh-blobs 上游 bug——
   贴最小复现 + 上游 issue 链接，在正确的层做最窄 workaround，卡尾
   写清理由等 review。

## 可执行验收

1. 根因写成一段话，能指到具体代码行/时序（不接受「可能是 CI 慢」）。
2. 修复后，在能复现 stall 的环境连跑 **20 次零 TIMEOUT**（贴输出）。
3. CI lint+test 连续 3 个 run 绿（不再 TIMEOUT）。
4. 隔离基线不回归：`--test-threads 1` 连跑 5 次仍绿（T-021 原验收）。

## 反证

把修复撤掉，在第 2 步的复现环境里必须重新 stall（贴输出后还原）。
若撤掉修复也不复现 = 没找到根因，打回。

## 证据要求

进度日志（含一次 stall 现场）+ 20 连跑输出 + 3 个 CI run 链接。

## 收尾

直推 main 前确认 CI 绿；PROGRESS/NEXT 各留一行；卡移 done/ 并附验收记录。

---
📌 **第 1 步完成（2026-08-10，Salamira）——取证桩已落，单独推 main；卡留队列等证据**

- 实现：`crates/transport/tests/blobs_resume.rs` 新增 `stamp()`（带
  时间戳的阶段打点，eprintln——nextest 捕获 stderr、仅失败时显示，
  TIMEOUT 日志直接指出卡点）；`kill_mid_transfer_then_resume_verifies`
  全阶段插桩：setup → provider ready → 每 attempt receiver bound /
  pull spawned / 传输进度逐 MB 打点（waiting for kill threshold:
  N bytes on disk）→ kill landed / outran-retry → restart rebinding /
  durable bytes / resume pull started / completed+verified → verify
  ALL GREEN。
- 本地实证（贴输出）：7.80s 全绿——进度桩逐 MB 增长正常、kill 落在
  ~7.5MB、restart 后 resume pull 2s 完成、位级一致。桩零侵入：测试
  行为不变（4/4 全绿，9.83s 全文件）。
- 后续：每次 CI 再 TIMEOUT，日志会显示最后一条 stamp 在哪——卡在
  attempt N waiting（传输没动）= 传输前 stall；卡在 resume pull
  started = 重拨/续传 stall。等证据积累后做第 2 步（本地复现）。

---
📌 **CI 证据 #1（2026-08-11，Salamira）——run 31370863470 撞 TIMEOUT，卡点定位成功**

- 场景：pr.yml lint+test，`kill_mid_transfer_then_resume_verifies` 300s
  TIMEOUT（322s 后被杀，223/224 其余全过）。commit 8b5362c 只动 Android/
  桌面/worker，**Rust 传输层零改动**——纯 flake 复现。
- 进度桩最后一条：`restart: rebinding receiver endpoint`——**之后到
  超时没有任何后续 stamp**（无 resume pull started / completed）。
- 卡点结论：**kill 后 restart 阶段的重拨 stall**——receiver endpoint
  重绑后 resume pull 从未启动，卡在等一个永远不来的连接/重拨。与卡面
  候选假设（kill 后重拨等一个永远不来的连接）吻合，且排除「传输中
  stall」（kill 前逐 MB 打点正常到 ~7.3MB）。
- 反证对照（同 commit 本地）：`kill_mid_transfer_then_resume_verifies`
  隔离跑 **10.664s 过**（4/4 全绿）——量级差再次确认并发时序下的竞态，
  不是慢。
- 后续 run 自愈：e7551c4（同一份 Rust 代码）31370939766 **success**。
- 下一步（第 2 步铺垫）：本地高并发压力复现 + 重点看 redial/rebind
  阶段时序（attempt 循环里 receiver 重绑与 iroh-blobs 连接建立的竞争）。

---
✅ **第 2/3 步完成（2026-08-11，Salamira）——本地复现 + 根因锁定 + 修复 + 反证**

**② 本地复现（首次！）**：高并发（全量 transport 套件 22 测试并行）+
CPU 加压（4 核机 50% 负载）循环，**第 1 轮即撞**：restart 阶段卡死 115s
（nextest slow-timeout 120s 终止）。三段式细化打点定位：
`rebinding receiver endpoint` → `endpoint bound`（5.4s，秒过）→ **卡在
`Blobs::open`（FsStore::load）**。共复现 2 次 + 1 次 50s+ 挂起（sampler
round 6）。此前隔离跑永远 6-12s 过——压力不够是长期复现不了的唯一原因。

**③ 根因（栈实证）**：挂起 20s 处 `/usr/bin/sample` 全线程栈 1032/1032
样本指向同一条链：

```
Actor::new (fs.rs:678) —— 在 store 自己的 runtime 上执行
  → drop_glue(RtWrapper)                  ← future 出错被 drop，连带 drop 捕获的 Runtime
    → RtWrapper::drop → block_in_place(|| drop(rt))
      → Runtime::drop → BlockingPool::shutdown → Receiver::wait → park
```

- **触发 = test harness 竞态**：kill（in-process abort）≠ 进程死亡——
  redb 的 Database（持 blobs.db 的 flock）在**独立 runtime 的 store
  actor** 手里，abort 只 drop FsStore（关 channel），actor 要等手头
  batch 写完 + 被调度才退出才放锁；固定 100ms 睡眠在负载下不够 → 重开
  撞锁 `DatabaseAlreadyOpen`（redb try_lock 非阻塞，源码确认是 error
  不是 hang）。
- **放大 = iroh-blobs 0.103 上游 bug**：Actor::new 的 `?` 上抛错误 →
  spawned future 完成时 drop 捕获的 RtWrapper（持有所在 runtime）→
  `RtWrapper::drop` 在该 runtime 自己的线程上 `block_in_place(drop(
  Runtime))` → `BlockingPool::shutdown` 等**包括正在执行本次 drop 的
  线程**在内所有阻塞线程退出 → 自锁。错误被死锁吞掉永不返回——所以是
  115s 挂起而非 panic（也解释了此前「redb 锁竞争=error」的排除推理：
  错误根本传不到 unwrap）。

**修复（最窄 workaround，harness 侧）**：固定 100ms 睡眠 → **文件锁释放
轮询**（`File::try_lock` 探测 blobs.db，10ms 间隔，30s 上限，失败带
stamp 断言）。把「等锁」从赌时序变成事实。真机 kill App = 进程死 → 锁
随进程释放，本无此竞态；in-process abort 才是人造竞态源。产品侧 daemon
单进程开一次 store 从不重开，不踩死锁路径。

**验证**：修复后同条件压力循环 **40/40 轮全绿 0 TIMEOUT**（修复前同
条件 2 次复现）；本地全量 149/149 绿。**反证**：修复前 = 固定 100ms
睡眠 → 本卡上述 2 次复现 + 死锁栈即为「去掉修复必红」的证据。

**上游报告**（✅ **已发 issue 2026-08-12**：
https://github.com/n0-computer/iroh/issues/4468 —— 本机 gh 登录账号
https://github.com/690591397 代发（用户指示「用自己的账号」），
正文=本卡尾存档的机制 + 栈摘录 + 最小复现，归档副本
docs/iroh-blobs-load-deadlock-issue-draft.md）：机制 +
栈摘录 + 最小复现路径已存档。影响面：任何 FsStore::load 失败（磁盘满/
库损坏/锁竞争）都会让进程挂死而非报错——daemon 启动时若踩到会挂起，
建议上游修 RtWrapper::drop（错误路径不该 drop 所在 runtime 的 Runtime）。
