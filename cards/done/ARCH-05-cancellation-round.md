# ARCH-05 取消本轮的持久扫描与恢复（L2）

> ✅ 状态：代码完成（本地验证通过）
> 级别：L2 · 前置：ARCH-02 手机账本、ARCH-03 严格消费者、ARCH-04 完成凭据

## 问题

“取消本轮”不能只取消眼前已发现的 500 项，也不能成为永久逐媒体黑名单。若
取消过程崩溃、还有未发现候选、或取消期间有新候选入队，旧实现无法保证哪些项
属于被取消的一轮、哪些属于下一轮。

## 期望行为

仅在用户 Pause 后执行 Cancel Current Round：先持久化 `CancellationRound`，当前
fetch 已停止；本轮已发现及之后分页发现的未完成候选都终态为
`CANCELLED_BY_USER_ROUND`。取消扫描可重启恢复；只有原子结束轮次后新入队的项
属于下一轮。Restore 和 Discard 都是显式用户动作。

本卡覆盖 Case Matrix：**X-01、X-02、X-03、X-04、X-05**。

## 验收标准

- [x] `ARCH01CancellationRoundTest` 覆盖 X-01~X-05；目标测试 10 tests / 0 failures。
- [x] X-01：900 项场景先取消当前 500，再继续分页取消其余 400；零项进入传输。
- [x] X-02：CancellationRound 活动期间入队的新项直接为
      `CANCELLED_BY_USER_ROUND`，不得短暂变为 `QUEUED`。
- [x] X-03：取消分页中崩溃重启后，从持久进度继续；不漏取消、不重复传输。
- [x] X-04：轮次原子结束后才入队的项属于下一轮，可正常 `QUEUED`。
- [x] X-05：Restore 仅重新准入该轮未完成取消项；Discard 只关闭快捷恢复，普通
      触发不许自动复活取消项。
- [x] 反证：新测试在实现前分别验证旧行为未取消已发现项、错误恢复其他轮次、关闭后
      不可 Restore/Discard、以及未完成项未取消；实现后均恢复为绿。
- [x] 全量 Android 单测：本次 XML 50 files / 371 tests / 0 failures / 0 errors / 4 skipped；`just ci` 全绿。

## 范围

- 只准动：ARCH-01 新账本中的 CancellationRound、取消进度、取消状态迁移与
  对应 JVM 单测。
- 不准动：旧 WorkManager cancel 行为、旧暂停开关、实际远端 cleanup、UI、
  Rust/desktop。
- 实际“停止 native fetch”的 adapter 调用仅通过 ARCH-03 的 port 表达；不在本卡
  新建或修改传输协议。

## 阻塞与依赖

ARCH-02 的发现事务必须支持“活动取消轮下直接终态入账”；ARCH-03 必须已保证用户
Pause 停止消费者；ARCH-04 必须已固定“已 CONFIRMED 不可取消”的完成事实。
2026-08-31 self-review 已确认 X-01~X-05 的轮次边界与 Restore/Discard 语义未被改写。

---

## 实施记录

- 2026-08-31：认领。当前节点：先为 X-01~X-05 建立 `ARCH01CancellationRoundTest` 并观察预期失败；下一步：实现持久取消扫描、恢复与丢弃的纯账本状态迁移；协同分支：`main`。
- 2026-09-01：完成。新增 `CancellationRoundController`，只在 ARCH-03 已 Pause 且无 fetch lease 时开启轮次；现存 `QUEUED`/`FAILED_NEEDS_USER` 项与活动轮次中新入队项均带轮次身份并转为 `CANCELLED_BY_USER_ROUND`，`CONFIRMED` 保持完成事实。结束轮次是同一账本快照边界；Restore 只重排本轮、Discard 只移除该轮的恢复资格。未触及旧 WorkManager、UI、Rust/desktop 或传输协议。

## 备注

来源：ARCH-01 §8 与 Case Matrix P0 取消本轮。它是可恢复的取消扫描过程，不是
“取消当前 Work”或一个含糊的布尔值。
