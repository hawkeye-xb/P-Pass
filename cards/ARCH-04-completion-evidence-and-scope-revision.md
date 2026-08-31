# ARCH-04 完成凭据与范围版本竞争（L2）

> ✅ 状态：代码完成（已释放 ARCH-05）
> 级别：L2 · 前置：ARCH-02 手机账本、ARCH-03 严格消费者

## 问题

旧系统将“开始传输”“批次 commit”“用户修改相册范围”混为一谈。范围减少与
迟到回执并发时，无法区分已经被 Desktop 完整保存的项和只有 partial 的项，容易
错误确认、错误取消或让旧范围继续完成。

## 期望行为

以 Desktop 的“完整接收、验证并可靠保存”凭据作为唯一完成证据。范围减少先
持久化新的 ScopeRevision、撤销旧未完成项的 lease；已有完成凭据的项始终确认，
没有凭据的旧项终态为 `CANCELLED_BY_SCOPE`。范围增加记录独立历史补扫，不复用
旧全局 DiscoveryCursor。

本卡覆盖 Case Matrix：**E-01、E-02、E-03、E-04**；并为 ARCH-02 发现器定义
ScopeRevision / backfill 的账本接口。

## 验收标准

- [ ] 先写 `ARCH01CompletionAndScopeTest`（或等价纯合同测试），执行
      `cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*ARCH01CompletionAndScopeTest'`
      → `BUILD SUCCESSFUL`，并覆盖 E-01~E-04。
- [ ] E-01：只有完成凭据可使 #18=`CONFIRMED` 并推进 UploadCursor；仅开始传输
      时确认必须变红。
- [ ] E-02：范围减少后迟到的有效完成凭据仍使 #18 保持 `CONFIRMED`。
- [ ] E-03：只有 partial / 无凭据的旧范围项变为 `CANCELLED_BY_SCOPE`，不得 finalise。
- [ ] E-04：Cancel Current Round 不得改变已确认项的完成事实。
- [ ] 范围增加产生历史补扫请求并在当前窗口终态后追加发现；范围减少保持新的
      ScopeRevision，重建新范围发现前不得继续旧 lease。
- [ ] 反证：把“开始 fetch”当完成凭据，或让范围变化覆盖已完成凭据 → 对应测试
      必须变红。
- [ ] 全量 Android 单测通过，并报告本次生成 XML 的测试总数与 0 failures。

## 范围

- 只准动：ARCH-01 新账本中的完成凭据、ScopeRevision、backfill 请求与状态迁移；
  对应 JVM 单测。
- 不准动：旧范围选择 UI、旧批次 commit / watermark 逻辑、实际 Desktop 协议实现、
  WorkManager 调度、Rust/desktop。
- 完成凭据的业务含义由 ARCH-01 固定；其 wire format 和 native adapter 属后续卡。

## 阻塞与依赖

ARCH-02 提供持久账本与发现事务；ARCH-03 提供严格 lease / consumer 行为。
2026-08-31 self-review 已确认 E-01~E-04 与范围增加/减少的既定语义完整映射。

---

## 实施记录

- 2026-08-31：E-01~E-04 先观察预期失败后实现完成凭据、ScopeRevision 与 backfill 状态迁移；范围增加独立记录 backfill，不改旧 DiscoveryCursor。
- 验证：E-01~E-04 + backfill 合同通过；反证实际变红后恢复：范围减少覆盖 CONFIRMED → E-02 红，取消范围后迟到凭据仍确认 → E-03 红；`just ci` 全绿。

## 备注

来源：ARCH-01 §7、Case Matrix P0 完成凭据与范围竞争。P0 的关键不是“范围变化时
取消所有项”，而是完成事实与未完成项必须被不同对待。
