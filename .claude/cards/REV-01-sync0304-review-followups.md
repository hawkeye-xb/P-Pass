# REV-01 SYNC-03/04 review 遗留——5 项 backlog　级别 L3【待排期，不阻塞当前线】

背景：2026-08-12 SYNC-03（QUIC 订阅）+ SYNC-04（Android 前台订阅）合并后
代码审查发现的遗留项。实现本身质量高（架构决策全对），以下为代码级
问题，按优先级排列，排期后逐项修。

## 1. serve_subscription 的 register 竞态（daemon，修复成本≈0）

位置：`crates/daemon/src/router.rs` `serve_subscription`。

执行顺序是：ack 发送 → initial push 发送 → `bus.subscribe()` → `subscriptions.register(peer)`。
窗口：**ack 已发给客户端但登记表还没有 entry**。若 owner 恰在此窗口内
`device.revoke` → ipc.rs 查表 `close(peer)` → 表里没有 → no-op；之后
register 才执行，这条订阅继续活着，还能收 `timeline.invalidated`
（总线转发不做鉴权复查）——被吊销的设备没被主动断连，直到自然断开。

修复：`register` 提到函数最前面（订阅请求一进来就登记，token 先拿到），
吊销窗口即覆盖整个订阅生命周期。微秒级窗口但零成本，顺手修。

## 2. 60s 兜底轮询整页覆盖，打断翻页（Android，UX 回归）

位置：`apps/android/.../ui/PhotosScreen.kt` 的兜底 `LaunchedEffect`。

兜底轮询调用 `refreshFullPage()`（整页覆盖语义）：`items = page(null).items`
（重置回第一页）+ `onTimelineRefreshed`（逐出不在首页返回集里的缩略图
缓存）。后果：用户翻到第 N 页，每 60s 被拉回第 1 页，翻页加载过的缓存
被逐出。

旧版 15s 轮询注释写明过正确语义：「只把没见过的 hash 插到最前面，不动
已加载内容/翻页游标，不触发 onTimelineRefreshed（整页替换会误逐出已翻页
加载的缩略图缓存）」——本卡丢了这条设计。

修复方向：订阅信号走整页覆盖（必须，删除可见性核心）；兜底轮询保持
「仅追加」语义（或 items 非空时跳过整页覆盖），两职责分开。

## 3. 反证测试未固化 + device.revoke IPC 接线层测试盲区（测试）

SYNC-03 卡片验收明确要求「临时跳过查表主动关闭 → 断言变红」的反证，
PROGRESS.md 声称做过但**未作为测试留在仓库**。且现有 revoke 集成测试
直接调 `subscriptions.close()`，绕过了 `device.revoke`（IPC JSON）→
ipc.rs 查表 → close 的真实链路——接线层（最易出错处）零覆盖。

修复：补一条走完整 IPC 的 `device.revoke` 集成测试（断言订阅连接在有限
时间内关闭），并把反证固化为测试（临时跳过 close 时断言必须变红）。

## 4. Android 吞 CancellationException（低）

位置：`PhotosScreen.kt` 订阅 effect 的 `catch (_: Throwable)`。
协程惯例应 `catch (e: CancellationException) { throw e }` 再抛。当前
行为上没问题（delay 会再抛），但取消状态可能被污染，顺手改。

## 5. wasLive 计时起点（低/可选）

`startedAt` 记的是 effect 开始（含重连尝试时间）而非连接建立时间——
「连了很久才建上、建上就断」的边缘情况会被误判为曾连上（退避不清零）。
影响微乎其微，修不修皆可。

## 收尾

每项修完补对应测试 + PROGRESS.md 一行。本卡为 backlog，等排期。
