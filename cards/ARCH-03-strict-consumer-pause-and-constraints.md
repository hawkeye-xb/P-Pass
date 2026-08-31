# ARCH-03 严格消费者、暂停与条件等待（L2）

> ✅ 状态：代码完成（已释放 ARCH-04）
> 级别：L2 · 前置：ARCH-02 手机账本与发现页原子提交

## 问题

旧系统把 WorkManager 通道、用户暂停、网络/电量等待与重试混在一起。结果是
“暂停后继续”会变成新 Manual 管道，条件恢复与用户 Continue 语义混淆，后续项
可能越过正在处理的项。

## 期望行为

实现 ARCH-01 的严格 UploadCursor 消费者：仅队头可取得 fetch lease；用户 Pause
只由用户 Continue 解除，条件不足进入 `WAITING_FOR_CONSTRAINTS` 并在条件恢复后
自动续当前项。两者不改变队列归属、范围版本、取消边界或失败预算。

本卡覆盖 Case Matrix：**C-01、C-02、C-03、C-04、C-05**。

## 验收标准

- [ ] 先写 `ARCH01StrictConsumerTest`（或等价纯消费者合同测试），执行
      `cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*ARCH01StrictConsumerTest'`
      → `BUILD SUCCESSFUL`，并覆盖 C-01~C-05。
- [ ] C-01：用户 Pause 时当前 #18 停止且 partial 归属保留；UploadCursor 不前进，
      #19 不得开始。
- [ ] C-02：Pause 后重启、后台唤醒、网络恢复与重复触发均保持 Pause；任一事件
      自动清 Pause 时测试变红。
- [ ] C-03：Continue 只恢复 #18，不创建 Manual / 全量新管道。
- [ ] C-04：Wi-Fi、电量或 Desktop 条件丢失时进入 `WAITING_FOR_CONSTRAINTS`；
      恢复后自动继续 #18，且不计入失败预算。
- [ ] C-05：永久错误耗尽预算后 #18=`FAILED_NEEDS_USER`；只有此终态才允许
      UploadCursor 前进到 #19。
- [ ] 反证：让 #19 在 #18 未终态时开始、把条件等待计作失败，或让网络恢复自动
      Continue 用户 Pause → 对应测试必须变红。
- [ ] 全量 Android 单测通过，并报告本次生成 XML 的测试总数与 0 failures。

## 范围

- 只准动：ARCH-01 新消费者 domain/application 模块、其 fake delivery port、对应 JVM 单测。
- 不准动：旧 `BackupWorker.kt` / `BackupUiStateHolder.kt` 暂停逻辑、WorkManager 调度、
  Android UI、实际 iroh adapter、Rust/desktop。
- 传输只能以可控 fake port 表达“停止 / partial / 完成 / 永久错误”；实际 native fetch
  接入属于后续传输 adapter 卡。

## 阻塞与依赖

ARCH-02 必须先提供可恢复的 TransferItem、UploadCursor、消费者 gate 与 lease 的账本边界。
2026-08-31 self-review 已确认本卡覆盖 C-01~C-05，不重开 Pause/Continue 的产品语义。

---

## 实施记录

- 2026-08-31：先建立 `ARCH01StrictConsumerTest`，C-01~C-05 因纯消费者与 fake delivery port 尚不存在而按预期编译失败；随后实现独立于 WorkManager 的严格消费者状态机。
- 仅 UploadCursor 队头能持有 fetch lease；Pause 持久化 consumer gate 并保留 partial，Continue 只重启原队头；条件等待不耗失败预算且自动恢复原队头；永久错误第 3 次才写 `FAILED_NEEDS_USER` 并推进至下一项。
- 验证：定向 C-01~C-05 5/5 通过；全量 Android JVM 单测通过。反证实际执行后恢复：让后台/网络唤醒绕过 Pause → C-02 红；将条件等待计作失败 → C-04 红；改为选队尾 → C-04 红。
- 2026-08-31：验收人已确认 GitHub `CI Android #95`（commit `c7543ae`）为绿色成功。

## 备注

来源：ARCH-01 §5~§6 与 Case Matrix P0 消费控制。调度器只负责唤醒/停止；它的状态
不可以作为 Pause、等待或队列顺序的业务事实。
