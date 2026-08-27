# UX-08 配对确认列表化 + 提示条治理　级别 L1　【队列第一】

## blocker（用户真机反馈 2026-08-10）

1. 「已允许 SM-S9210 加入」提示写进 `message` 状态后**没有任何清除机制**
   （App.svelte，只有下次开配对弹窗才被顺手清空）——一直挂着。
2. 多台同时扫码时确认弹窗一次只弹一台、处理完再弹下一台，用户不知道
   后面还排着几台。

## 方向（用户已拍板）

- pending 请求**全部列出来**，一屏一个列表，每行：设备名 + 允许/拒绝
  两按钮，处理完该行消失，全部处理完列表关闭。用户在电脑跟前，
  一个个点是自然交互，不要顺序弹窗挤牙膏。
- 成功/失败提示条：自动消失（约 5s）+ 右侧 × 手动关闭，两者都要。

## 范围

apps/desktop（App.svelte + i18n 字典）。daemon IPC 的 pending 队列如果
只吐一条（`pairing.confirm` 现语义），需要 `pairing.pending` 列表方法
则连带 crates/daemon/src/ipc.rs（只读方法，不动确认语义）。

## 可执行验收

1. 模拟 3 台同时扫码（测试可直接向 pending 队列注入）→ UI 一屏三行，
   逐行允许/拒绝，行随处理消失，全清后无残留状态。
2. 允许后提示条 5s 自动消失；手动 × 立即消失。
3. vite build 绿；若动 daemon 则 nextest 相关包绿。

## 反证

把自动消失定时器去掉 → 验收 2 必挂（贴行为对照后还原）。

## 收尾

CI 绿；PROGRESS/NEXT 一行；卡移 done/。UI 走查欠账照记（真窗口截图
挂验收人）。

---

## 验收记录（2026-08-11 Salamira）

- daemon：只读 IPC `pairing.pending`（pending_names 全量；confirm 带
  device_name 逐台精确确认，不带则队首——语义零改动）。
- 桌面：pendingList 全量渲染逐行 allow/deny；flashMessage 统一 14 处
  t() + 2 处硬编码赋值（5s 自动消失 + × 手动关闭）；CSS token 色。
- 测试：ipc_flow **8/8**（新增 pairing_pending_lists_all_waiting_then_
  confirm_by_name——三台独立 token 入队→列表三行→按名确认中间→剩两台→
  全清后 pending 空 + status.pending_pairs=0 + 设备表含被允许的 B）；
  vite build 绿（173 modules）；cargo fmt clean。
- CI：run 31368612144 等待中（commit 07cd1b9）。
- 挂验收人：①模拟 3 台同时扫码真窗口一屏三行逐行处理截图；②提示条
  5s 自动消失 + × 手动关闭实机观感；③反证：去掉自动消失定时器 →
  提示条常驻（贴对照后还原）。
- 坑：多台测试同一一次性 token 会被引擎拒（token 单用）——每台独立
  铸 token（Pairing::start 可多铸共存）。
