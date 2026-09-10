# MOB-67 "备份失败时通知我"开关未接任何系统通知（L2）

> ⚫ 状态：已合并到 MOB-68（2026-09-10）；本卡保留已核实根因与失败通知验收素材
> 级别：**L2** · 阻塞：MOB-68

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

## 期望行为（已纳入 MOB-68）

用户打开"备份失败时通知我"后，一次真实的备份失败应当收到系统通知
（App 内 Home 红卡展示不受影响，通知是补充渠道）；用户关闭该开关则不发送。
需要处理 Android 13+ 的 `POST_NOTIFICATIONS` 运行时权限缺失情形（参考
`ReuploadNotice.kt` 头部注释里对失败路径的既有分析）。

## 验收标准（已纳入 MOB-68）

- [ ] 找到当前 Flow 失败/永久失败回调链路的正确接线点（不是重新发明一套
      通知基础设施，复用已有的 Notification Channel 若存在，否则新建）。
- [ ] JVM：`NotifyOnFailurePrefs.enabled() == true` 且触发一次失败 →
      通知发送被调用；`enabled() == false` 时不调用。
- [ ] 反证：把开关判断去掉，上一条用例必须变红（或反过来验证关闭确实
      拦住发送）。
- [ ] 真机：开启开关触发一次真实失败，收到系统通知；关闭开关触发失败，
      不收到通知。

## 范围（已纳入 MOB-68）

- 只准动：`apps/android/.../backup/`（失败回调链路接入通知发送）、
  `NotifyOnFailurePrefs` 消费点、对应 JVM 测试。
- 不准动：`ReuploadNotice.kt` 的独立重传通知逻辑；Home 页红卡渲染文案；
  MOB-64 的 pairingLost 识别逻辑。

## 阻塞与依赖

MOB-68。不得独立实施，避免通知权限、设置开关和失败发送链路被拆成不一致的两套语义。

---

## 备注

来源：2026-09-10 MOB-64 真机验收过程中顺带发现，与 MOB-64 本身的
pairingLost 识别是两个独立问题，不要混在一张卡里改。
