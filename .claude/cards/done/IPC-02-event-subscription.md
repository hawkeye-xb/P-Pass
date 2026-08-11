# IPC-02 IPC 事件订阅——桌面壳告别轮询　级别 L2（用户裁决 2026-08-12）

## 背景

用户原话：「为什么是轮询这种体验、实现、内存都不友好的方式？」——说
得对。现状 IPC 是一调用一连接的请求/应答（T-034），桌面壳 3s 轮询
status/pending/watermarks，配对这种强交互时刻延迟高达 3s（QR 弹窗
挡住授权列表的直接原因），平时又在空转。

## 修法

daemon IPC 增加 **subscribe 通道**：客户端发 `events.subscribe`
（可带类型过滤）后连接保持，daemon 在事件发生时沿该连接推送
newline JSON 事件帧：
- `pairing.pending_changed`（QR 弹窗即时切换的关键）
- `status.changed`（服务态/版本）
- `activity.appended`（活动流新条目）
- `device.changed`（配对/移除/水位推进）

桌面壳：启动即订阅，UI 状态改事件驱动；轮询降级为**兜底**（如 60s
一次对账，防漏事件），不再是主通道。断线重连 + 重连后全量刷新一次。

## 不准动

现有七方法请求/应答语义（订阅是新增不是改造）；token 认证流程
（订阅连接同样先过 token）。

## 可执行验收

1. 集成测试：订阅后注入配对请求 → 事件帧 <100ms 到达（对照轮询 3s）。
2. 桌面联调：扫码 → QR 弹窗即时关、授权列表即时出（贴时序日志）。
3. 断 daemon → 壳自动重连重订阅，状态恢复（贴日志）。
4. 反证：取消订阅路径 → UI 退回兜底轮询仍能工作（降级可用性）。
5. 全量测试绿；壳侧无高频 setInterval 残留（grep 轮询间隔）。

## 收尾
CI 绿；PROGRESS/NEXT 一行 + ROADMAP 状态；卡移 done/。

---

## ✅ 验收记录（2026-08-11，Salamira）

- 实现：本 commit（main 直推，速度优先阶段）。daemon 新增 events 模块
  （broadcast 事件总线，4 事件常量）+ IPC events.subscribe 订阅通道
  （serve_subscription 双工循环：继续应答普通请求 + 广播事件帧推送，
  types 过滤、unsubscribe/断开即关）；触发点：pending_rx 入队 +
  confirm 出队（IpcServer）、device.revoke（IpcServer）、backup.commit +
  device.unpair（Router，with_events 可选注入）、配对落定（Pairing，
  with_events）。桌面壳：DaemonHandle::subscribe_events 长连接 +
  start_event_stream command（setup 启动、2s 退避重连、老 daemon 静默
  降级）+ App.svelte listen("daemon-event") 事件驱动刷新，3s 轮询 →
  60s 兜底。
- 验收 1（集成测试）：订阅后注入配对请求 → pending_changed 事件帧
  实测 **36ms**（<100ms 达标，对照轮询 3s）。走真实 pending 入队链路
  （Pairing.handle_request → pending_tx → IpcServer 队列）。**PASS**。
- 验收 4（反证）：①类型过滤——只订阅 status.changed 的连接 200ms 内
  收不到 pending 事件；②events.unsubscribe → 连接被服务端关闭
  （next_line EOF）。**均 PASS**。
- 验收 5：壳侧 grep 无高频 setInterval 残留——唯一 setInterval 为
  60s 兜底对账。
- 全量：Rust **237/237**（234+3）+ clippy 0 warning + fmt 干净 +
  arch-check ✅ + vite build 绿 + src-tauri cargo check 绿。
- 验收 2/3（桌面联调）挂账：扫码 → QR 弹窗即时关/授权列表即时出
  （时序日志）；断 daemon → 壳自动重连重订阅状态恢复。
