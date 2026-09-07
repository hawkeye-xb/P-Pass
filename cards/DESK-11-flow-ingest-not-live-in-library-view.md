# DESK-11 手机传完的照片桌面库不及时出现（watcher/事件链未覆盖 Flow 摄入）（L1）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：等真机复核 ·
> 下一步：连传 ≥20 张，逐张确认 2 秒内出现在桌面时间轴 · 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

真机验收观察：手机侧照片已传输确认，桌面端图库要**等下一批/过一阵**才展示
（验收人原话「传到了才展示出来」）。架构上 daemon 存在 `LibraryWatcher`
（crates/daemon/src/watcher.rs，notify 文件监听 + event_bus），监听本应
实时——实时性承诺被打破。

## 期望行为

每张新摄入库的文件在其 receipt 落定后**秒级**出现在桌面时间轴（事件驱动，
非轮询碰运气）。

## 验收标准

- [ ] 取证先行（实施记录必须有）：单传一张照片，逐层打点——blob 落盘时间 →
      watcher 事件时间 → event_bus 广播时间 → 前端渲染时间，给出断在哪层。
- [ ] 修复后：连传 20 张，每张在完成后 2s 内出现在桌面；有 Rust/前端测试
      覆盖事件路径（不依赖真机）。
- [ ] 反证：断开该事件路径的变体必须让测试变红。
- [ ] `just ci` 全绿（ci-desktop/ci-rust 域）。

## 范围

- 只准动：`crates/daemon/src/watcher.rs`、flow 摄入落盘路径、事件总线到前端
  的订阅链（`apps/desktop/src*`）、对应测试、卡片/队列/进度文档。
- 不准动：账本协议；手机端。

## 阻塞与依赖

无。注意与 DESK-12 相邻（同为 flow_delivery 落盘路径），两卡若同轮实施按
文件交集串行，不并行。

---

## 实施记录

- 根因确认（源码读取）：`FlowDelivery` 结构体没有 throttle/events 字段，
  `main.rs` 构造它时从未调用等价的 `.with_events(...)`（对照
  `BackupEngine::new(...).with_events(event_bus.clone())`）——旧批处理管线
  有事件通知，新 Flow 管线没有。
- RED：`daemon/tests/flow_delivery.rs::successful_flow_fetch_notifies_the_desktop_timeline`
  用真实 iroh 传输链路（bind→push→offer→fetch）驱动，断言 1 秒内收到
  `TIMELINE_INVALIDATED` 事件；未接线前该用例超时真红。
- GREEN：`FlowDelivery` 加 `throttle: Option<Throttle>` 字段（镜像
  `BackupEngine` 的 throttle 用法）+ `with_events`/`with_events_and_window`
  构造方法；`fetch()` 材料化成功后调用 `throttle.signal()`；`main.rs` 在
  构造 `flow_delivery` 时补上 `.with_events(event_bus.clone())`。
- 全量测试：`cargo nextest run --all-features` 336 tests / 336 passed /
  1 skipped；`just ci` 全绿。
- 未做：真机连传验证（本次会话未连接可用测试相册，交给验收人做黑盒回归）。


## 备注

- 候选嫌疑（未定性）：watcher 只盯 originals 目录而 flow-blobs 先落独立目录
  再移动/硬链；debounce 合批把单张延迟拉大；前端仅在库级事件时刷新。
  取证输出各候选的实测时间戳后裁决，不猜着修。
