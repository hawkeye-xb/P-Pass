# ARCH-05 取消本轮的持久扫描与恢复（L2）

> ⬜ 状态：未开工（待验收人 review；未通过 review 禁止实施）
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

- [ ] 先写 `ARCH01CancellationRoundTest`（或等价纯合同测试），执行
      `cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*ARCH01CancellationRoundTest'`
      → `BUILD SUCCESSFUL`，并覆盖 X-01~X-05。
- [ ] X-01：900 项场景先取消当前 500，再继续分页取消其余 400；零项进入传输。
- [ ] X-02：CancellationRound 活动期间入队的新项直接为
      `CANCELLED_BY_USER_ROUND`，不得短暂变为 `QUEUED`。
- [ ] X-03：取消分页中崩溃重启后，从持久进度继续；不漏取消、不重复传输。
- [ ] X-04：轮次原子结束后才入队的项属于下一轮，可正常 `QUEUED`。
- [ ] X-05：Restore 仅重新准入该轮未完成取消项；Discard 只关闭快捷恢复，普通
      触发不许自动复活取消项。
- [ ] 反证：只取消当前窗口、取消期间让新项进入队列、或重启重置取消进度 →
      对应测试必须变红。
- [ ] 全量 Android 单测通过，并报告本次生成 XML 的测试总数与 0 failures。

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
待验收人 review：确认 X-01~X-05 的轮次边界与 Restore/Discard 语义未被改写。

---

## 实施记录

- 尚未实施。

## 备注

来源：ARCH-01 §8 与 Case Matrix P0 取消本轮。它是可恢复的取消扫描过程，不是
“取消当前 Work”或一个含糊的布尔值。
