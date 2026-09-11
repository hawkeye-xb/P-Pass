# MOB-67 "备份失败时通知我"开关未接任何系统通知（L2）

> 🟡 状态：代码完成（2026-09-11），待三星真机验收
> 级别：**L2** · 阻塞：无

## 根因（比卡面初稿更深一层，考古结论）

不是"从未实现"，是**被生产切换删掉的**：UX-02（2026-08-05, PR #36）曾在
BackupWorker 里有完整实现（`ppass.backup.failed` 渠道、固定 id 2027、
`NotifyOnFailurePrefs.enabled()` 闸控、点开进 MainActivity）；REBUILD-04
切换（commit `a325208`，Worker 降级为纯 wake adapter）删除 1124 行时整套
通知设施随批次管线一起消失，新 Flow 的失败链路从未接回。同批被删的还有
SENT-01 哨兵（id 2028）、DOG-02b 白名单提醒（id 2029）、MOB-29 重传通知
（id 2030）的发送端——字符串资源全部还在字典里，发送代码没了。本卡只按
卡面范围接回失败通知；其余三条的缺失已开衍生卡（见文末）。

## 修法

- 新 `backup/FailureNotifier.kt`：JVM 可测的接口边界（enabled + postFailure）。
- `StrictConsumer.recordPermanentFailure()` 返回本调用是否驱动了
  attempt-3 终态跃迁（在 `ledger.update` 突变内部捕获，不做事后重读）。
- `FlowRunner.recordPermanentFailure()` 在终态跃迁后、且开关开启时，
  从账本数 `FAILED_NEEDS_USER` 总数发一条（固定 id 折叠重复，第二次失败
  是更新不是再响一次）；`runCatching` 吞发送异常——账本先落盘，通知是
  补充渠道（MOB-37 裁决：通知退化成"提醒你去看"）。
- 新 `backup/SystemFailureNotifier.kt`：沿用历史渠道 id/通知 id 2027
  （用户已调过的渠道设置不丢）；渠道名从硬编码双语进 en/zh 字典
  （`notif_channel_backup_failed`）。
- `AndroidFlowRuntime` 构造点接线；瞬态重试（attempt 1/2）保持沉默。

## JVM 测试

`MOB67FailureNoticeTest` 三条：终态发一条+瞬态零发 / 开关关不发但账本照跃迁
（反证基础）/ MOB-54 自动续跑回归。

## 问题

2026-09-10 MOB-64 真机验收过程中发现：设置页"备份失败时通知我"开关
（`NotifyOnFailurePrefs`）打开后，触发一次真实备份失败（截图触发传输、
Home 页出现红色「本次备份没有完成」失败卡），**没有收到任何系统通知**。

源码核实：`NotifyOnFailurePrefs` 全仓只有一处读取——
`MainActivity.kt:519` `notifyOnFailurePrefs.enabled()`，仅用来初始化设置页
开关自身的勾选状态。全仓搜索 `NotificationChannel`/`Notification.Builder`/
`NotificationManagerCompat` 均未命中这个开关；`BackupWorker`/
`NativeFlowDeliveryPort` 等失败路径都不读取这个偏好、也不发系统通知。

`ReuploadNotice.kt` 里有一条相似但独立的通知逻辑（`noteReuploadNotice`
的 `notify: () -> Unit` 回调），处理的是"重传告知"，与本卡的"备份失败
通知"是两个不同场景，不能混用。

## 期望行为

用户打开"备份失败时通知我"后，一次真实的备份失败应当收到系统通知
（App 内 Home 红卡展示不受影响，通知是补充渠道）；用户关闭该开关则不发送。
需要处理 Android 13+ 的 `POST_NOTIFICATIONS` 运行时权限缺失情形（参考
`ReuploadNotice.kt` 头部注释里对失败路径的既有分析）。

## 验收标准

- [ ] 找到当前 Flow 失败/永久失败回调链路的正确接线点（不是重新发明一套
      通知基础设施，复用已有的 Notification Channel 若存在，否则新建）。
- [ ] JVM：`NotifyOnFailurePrefs.enabled() == true` 且触发一次失败 →
      通知发送被调用；`enabled() == false` 时不调用。
- [ ] 反证：把开关判断去掉，上一条用例必须变红（或反过来验证关闭确实
      拦住发送）。
- [ ] 真机：开启开关触发一次真实失败，收到系统通知；关闭开关触发失败，
      不收到通知。

## 范围

- 只准动：`apps/android/.../backup/`（失败回调链路接入通知发送）、
  `NotifyOnFailurePrefs` 消费点、对应 JVM 测试。
- 不准动：`ReuploadNotice.kt` 的独立重传通知逻辑；Home 页红卡渲染文案；
  MOB-64 的 pairingLost 识别逻辑。

## 阻塞与依赖

无。MOB-68 已完成通知权限申请与开关呈现；本卡只消费该已授权的偏好，接通失败
事件到系统通知发送，不能改动 MOB-68 的 onboarding/权限交互。

---

## 备注

来源：2026-09-10 MOB-64 真机验收过程中顺带发现，与 MOB-64 本身的
pairingLost 识别是两个独立问题，不要混在一张卡里改。
