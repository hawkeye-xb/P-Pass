# NET-11 桌面壳 IPC 同步 call 加固定读超时（daemon_call 透传无死因保险丝）　级别 L1

> ⬜ 状态：未开工（2026-09-14 NET-08 普查产出，焊点 D1）
> 级别：L1 · 阻塞：无
> **AGENTS.md 设计纪律登记：本卡是终态方案（本地 IPC 保险丝即正确形状，
> 非止血）；无需另开根治卡。**

## 问题

NET-08 普查（焊点 D1）：桌面壳到 daemon 的本地 socket IPC 完全没有读超时
——形状与 NET-01 同族（调用方只凭「回声来没来」推断，且这里连「回声
会不会到」都没有上限）：

- `apps/desktop/src-tauri/src/ipc.rs:100` `DaemonHandle::call`：同步
  `Stream::connect` + `BufReader::read_line`（`:118`），若 daemon 活着但
  内部处理挂住（tokio 阻塞盘 IO——DESK-13 是同族前科；或未来任何慢
  handler），`read_line` 永久阻塞。
- 后果不是「一个请求卡住」而是**整壳卡住**：`daemon_call`（lib.rs:64）是
  同步 `#[tauri::command]`，Tauri v2 同步 command 占线程池名额；前端
  轮询（3s 节奏的状态刷新 + PhotoThumb 逐张 `thumb.get`，App.svelte:190
  一个透传打全部本地方法）会不断堆积挂死 command，耗尽 blocking 池后
  窗口事件循环连带冻结——用户看到的是整个 App 无响应，且没有任何
  「谁挂了」的线索。
- 唯一带时限的调用点是 DAE-01 的 `peer_call`（daemon 侧探活，800ms，
  `crates/daemon/src/ipc.rs:105`）——恰是壳侧没抄的这个。

## 期望行为

1. `call()` 加**单一固定读超时**（卡定 10s：本地 socket 上任何合法
   handler 都不该让人类等 10 秒；`thumb.get` 的 daemon 侧预算 5s + 余量，
   `pairing.confirm` 在 daemon 侧解 oneshot 即回、人类等待不进 IPC 读路径）。
   超时抛 `Err("ipc timeout: {method} > 10s")`——**方法名必须进错误串**。
2. 禁止按方法动态推算超时（NET-07 同款红线：启发式=摆钟复发）；一个
   数，注释写明它是「daemon 挂死检测保险丝」不是「预期耗时」。
3. 超时后连接直接丢弃（现有每调一新连接的模式天然满足），前端收到
   Err 走既有「后台服务失联」横幅路径，不新开提示渠道。
4. `subscribe_events`（长连接，设计上是等事件）不加超时——豁免理由写进
   代码注释：它已有断线重连环（lib.rs:81 `start_event_stream` 2s 退避）。

## 验收标准

- [ ] RED 先行（rust 单测）：假 IPC 服务端「收下请求永不回行」→
      `call()` 必须在注入的短阈值内返回 Err 且错误串含方法名；改前真红
      （永久挂起 → 测试超时即红）。
- [ ] 反证：正常回行的方法不得触发超时；`pairing.confirm` 挂等待决策时
      （pending 未决）走它的是 status/pending 查询不是 confirm——确认
      本卡超时值不吞正常长等待路径（集成测试列出全部本地方法与 10s
      预算的对照表贴进实施记录，NET-07「漏归=违规」同口径）。
- [ ] 桌面壳 vitest：前端对 `Err("ipc timeout…")` 的呈现断言（走既有
      banner 状态）。
- [ ] `just ci` 全绿（改 apps/desktop/** → 盯 ci-desktop）。
- [ ] 真机顺路：daemon 运行中 `kill -STOP` 再 `kill -CONT`，期间桌面 UI
      显示失联提示而非冻死，恢复后自动回到正常（NET-01 真机窗口顺路跑）。

## 范围

- 只准动：`apps/desktop/src-tauri/src/ipc.rs`（call + 超时常量）、
  `apps/desktop/src-tauri/src/lib.rs`（仅错误文案接线，如需）、对应测试、
  卡片/队列文档。
- 不准动：daemon 侧 `crates/daemon/src/ipc.rs`（本地 socket 服务端）、
  前端组件、NET-06/07/09/10 范围内任何文件。

## 阻塞与依赖

无。DESK-13 若落地 spawn_blocking 化，与本卡正交（那治「handler 慢拖垮
runtime」，本卡治「壳无死因保险丝」），互不阻塞。

---

## 实施记录

（待补）

## 备注

- 10s 的来历：> daemon 侧最重的同步路径预算（thumb 5s）+ 一倍余量；
  < Tauri blocking 池被拖垮的体感阈值。实施时用真机 `pairing.confirm`
  长挂场景复核一次（DESK-13 的教训：别只对着代码定数）。
- W5 口径：`interprocess` 非阻塞模式 + 手动 deadline 是标准做法；已核查
  无自带超时 API，不背「库是哑巴」锅。
