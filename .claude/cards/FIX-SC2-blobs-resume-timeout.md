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
