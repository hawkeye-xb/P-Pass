# MOB-18 force-stop 中断检测与提示　【BACKLOG · 2026-08-19 用户拍板 pending】

## 为什么 pending

用户在系统设置里「强行停止」App 后，JobScheduler 会清空该 App 的全部
job。想给用户一条「后台备份停过」的提示，并且**由用户点了才恢复**
（用户原话："必须点了才恢复。你都提示了，就别自作主张。"）。

真机实测发现**后半句做不到**：

```
force-stop 前  JobScheduler job 数: 2
force-stop 后  JobScheduler job 数: 0
重开 App 后    JobScheduler job 数: 2   ← 没等我们的代码动手就恢复了
```

WorkManager 有个内建的 `ForceStopRunnable`，跑在 `androidx.startup` 的
ContentProvider 里——**比 `Application.onCreate` 还早**——它检测到 App
被强停过就把所有未完成 work 重排一遍。这发生在我们任何一行代码之前，
应用层拦不住。

于是这个功能只能做成"检测到 → 提示 → 但其实早就自愈了"，那条
「点这里重新开始」的按钮是假的。用户判断：**语义不诚实的提示不如不做**，
先放 backlog。

## 已经验证过、可直接复用的结论

1. **判据必须两边对账**，这是踩过坑的：只查
   `getWorkInfosForUniqueWork` **完全无效**——那读的是 WorkManager 自己
   的数据库，force-stop 不动它，判据恒真（初版就是这么错的，提示一次都
   没亮过）。正确判据是「WorkManager 认为有活儿在排 **且**
   `JobScheduler.getAllPendingJobs()` 为空」＝被外力清空。
   只查 JobScheduler 也不行：未配对/已暂停时本来就没 job，会误报。
2. 检测是**主动查询**（一次本地库读），不需要 App 常驻、不需要监听。
   但会阻塞，得放后台线程。
3. 顺序不能反：检测必须在 `scheduleAutoBackup` 之前，否则监听刚被重排
   上，判据永远为真。

代码保留在 `backup/BackupHealth.kt`（当前无人调用，文件头有标注），
`BackupHealthTest` 保留数据结构部分的测试。UI 提示条、`MainActivity` 与
`PPassApplication` 的接线均已撤除。

## 若将来重做，可能的方向

- 换个信号：不追「是不是被 force-stop」，而是「距上次成功备份多久」——
  这个信号更有用（覆盖电脑不可达、条件长期不满足等所有停摆原因），而且
  项目里已有 SENT-01 哨兵机制可复用，也许只需调阈值。
- 或者接受 WorkManager 会自愈，把提示改成**如实陈述**：「后台备份中断
  过（X 到 Y），已自动恢复，期间的照片正在补传」——只报信息不假装给
  选择权。
