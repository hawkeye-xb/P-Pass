# SYNC-03 QUIC 平面订阅入口 + 连接登记表 + 吊销主动断连　级别 L2【依赖 SYNC-02 已合并】

背景与全部裁决点见 `docs/product/2026-08-12-metadata-sync-decisions.md`
（§①③⑦，本卡只实现这三条）。**前置条件**：SYNC-02 的
`timeline.invalidated` 已合并进 main——本卡是它的第一个消费者。

## 目标

`router.rs`（手机走的 QUIC 网络平面）补一个 `subscribe` 方法，模式照抄
本地 IPC 已跑通的 `events.subscribe`/`serve_subscription`；新增一份
`NodeId → 活跃订阅` 的登记表；吊销（无论是别人吊销还是自己退出）都要
主动查表断连，不是等它自然过期。

## 范围

只准动：
- `crates/daemon/src/router.rs`（新增 subscribe 方法分支、登记/摘除
  钩子、`handle_unpair` 里内联摘除自己）
- `crates/proto/src/msgs.rs`（新增 subscribe 请求/响应的消息类型，
  版本兼容——旧客户端不发这个方法，服务端不强制）
- `crates/daemon/src/ipc.rs`（仅改 `device.revoke` 处理函数，加一步
  查登记表主动断连；不改这个文件里 IPC-02 已有的本地事件订阅逻辑）
- 新文件（如需要）：`crates/daemon/src/subscriptions.rs`（登记表本身）

## 不准动

- `events.rs` 内部的节流合并逻辑（SYNC-02 已完成，本卡只是消费其
  emit 出的事件，不重新实现节流）
- Android 端任何代码（SYNC-04）
- `proto::AssetMeta` 字段（SYNC-05）

## 设计要点

- `subscribe` 是一个普通 `Req`，**一样要过 `authz::check`**——不因为
  是"订阅"就绕开鉴权检查点，这条路径跟 `timeline.page` 等方法平级。
- 订阅建立成功的那一刻，立刻主动 emit 一次 `timeline.invalidated`
  给这个新订阅者（§③"订阅即返回当前态"）——不等下一次真实变更。
- 之后这条订阅只推 `timeline.invalidated` 这一种 ping，**不携带任何
  照片数据**；手机要拿数据永远走独立的、每次都鉴权的请求（可以是
  同一条底层 QUIC 连接上的另一条 stream，省的是握手，不是省鉴权）。
- 登记表：`NodeId → 关闭该连接的 handle`。连接因为任何原因结束（对端
  正常关闭/网络异常掉线）都要自动从表里摘除，不能留僵尸记录。
- `handle_unpair`（手机自己发起退出）：处理这个请求时，顺手把自己的
  登记摘掉。
- `ipc.rs` 的 `device.revoke`（桌面吊销别人）：调用 `db.revoke` 之后，
  查登记表，命中就主动关闭那条连接（发送关闭信号或直接 drop 连接
  handle）。
- **红线**：`iroh` 具体类型不能从 `transport` crate 漏出去（`router.rs`
  只能拿到 `transport` 已经包好的抽象，不能直接 `use iroh::...`）——
  `just arch-check` B.1 段会挡这个。

## 可执行验收

- 集成测试：手机端建立订阅连接后，daemon 侵入触发一次 ingest → 断言
  该连接**恰好**收到一次 `timeline.invalidated`（不是零次也不是因为
  订阅即返回当前态那次而变成两次——需要把"订阅建立时的那一次"和"真实
  变更触发的那一次"在断言里分开算清楚）。
- 集成测试：吊销一个当前挂着活跃订阅的设备 → 断言该连接被**主动**
  关闭（对端读到 EOF/连接错误），而不是停留在"连接看起来还活着，只是
  服务端不再回应"。
- **反证**：临时跳过"查表主动关闭"这一步（吊销只改数据库）→ 上面
  这条断言必须变红（证明判据真的在测主动断连，不是恒真式，也证明
  "自然超时导致连接消失"不会被误判为"主动断连成功"）。
- `just arch-check` 绿（B.1 iroh 隔离）。

## 证据要求

集成测试真实输出摘要 + 反证的失败输出 + `arch-check` 输出。

## 跨卡声明禁令

不许写"SYNC-04（Android）已能用"——手机端代码在本卡完成时可能还没接，
本卡的验收对象是 daemon 侵入测试模拟的假客户端，不是真手机。

## 收尾

`cargo test`（daemon + proto）全绿 + `just arch-check` 绿 + PROGRESS.md
一行 + 本卡移入 `done/`。

---

### 执行记录（2026-08-12）

- `proto::msgs::methods::TIMELINE_SUBSCRIBE`（`"timeline.subscribe"`）
  新增；`authz.rs` 加进 `viewer_ok`（任何已配对角色可订阅，跟
  `timeline.page` 同级），未配对/已吊销一律拒绝（补了对应单测）。
- `crates/daemon/src/subscriptions.rs`（新文件）：`SubscriptionRegistry`
  用 `tokio_util::sync::CancellationToken`（库原语，不是手搓 channel）
  + `Arc` 内部共享，`Clone` 廉价；`generation` 计数器防止旧订阅流收尾
  的 `unregister` 误删同设备刚建立的新登记。单测 3 条。
- `router.rs`：`serve_stream` 在 authz 通过后拦截
  `TIMELINE_SUBSCRIBE`，转入 `serve_subscription`——发 ack、立即推一次
  当前态（§③，不广播给其他订阅者)，然后 `tokio::select!` 三路（吊销
  token/客户端读取/事件总线），只转发 `timeline.invalidated`。
  `handle_unpair` 收尾顺手 `subscriptions.close(peer)`（自我退出）。
- `ipc.rs` 的 `device.revoke`：`revoked` 分支里补
  `self.subscriptions.close(...)`，与 Router 共用同一份登记表（main.rs
  建一份 `SubscriptionRegistry`，`with_subscriptions`/`set_subscriptions`
  各喂一份 clone）。
- 新集成测试 `daemon/tests/subscribe_flow.rs`：
  `subscribe_relays_a_real_broadcast_event`（订阅→ack→初始推送→真实
  broadcast 事件也能收到）+
  `revoke_actively_closes_an_open_subscription`（revoke 后连接在
  3 秒超时内必须结束）。反证：临时注释掉测试里的 `subscriptions.close`
  调用 → 后一条测试从绿变红（超时 panic），证明断言测的是真机制不是
  恒真式；改回后重新全绿。
- 证据：`cargo test -p daemon -p proto -p core-index` 全绿（新增 3+2
  个单测 + 2 个集成测试）；`just arch-check` 绿；`cargo fmt --check`
  干净。**未推 GitHub**——按用户要求先在本地把 daemon 侧和后续
  Android 真机联调一起验证完再决定是否推送。
