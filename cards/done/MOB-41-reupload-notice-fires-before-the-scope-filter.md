# MOB-41 重传提示发在范围过滤之前——删掉范围外的照片会弹一条假通知　级别 L2

> ✅ 状态：**已被生产架构取代，归档**（2026-09-07）。本卡点名的
> `BackupWorker.runBackup`/`calibrateIfReachable` 函数在当前代码里**已不存在**；
> 它依赖的 `calibrateConfirmed`/`planReuploads`/`noteReuploadNotice` 三个函数
> 虽然还在源码里，但生产代码（`apps/android/app/src/main`）里**零调用**——
> 只有单元测试还在引用，属于 REBUILD-00 冻结的旧批处理管线遗留代码，与
> MOB-39/42/48 同族。真正的重传/校准语义已转移到 `backup/flow/` 包
> （`RemoteReconciliation`/`CompletionAndScope`），走的是发现队列 + 严格单
> 消费者的新架构，不存在"通知发在范围过滤之前"这个旧时序问题。
> 级别：L2 · 阻塞：无

## 问题

`BackupWorker.runBackup` 里两件事的顺序是反的：

```
calibrateIfReachable(...)          // 发现 confirmed 的资源在远端消失 → 入队 + 发通知
  └─ noteReuploadNotice(...)       // ← 通知在这里发（MOB-37）
val bucketIds = ...selectedBucketIds()
val plan = planReuploads(... inScope = { bucketId in bucketIds })
reuploads.remove(plan.drop)        // ← 范围外的在这里才被丢掉
```

于是：**用户在桌面删掉一张已经不在备份范围内的照片，手机会弹「正在重传」，
然后什么也不传**（那条队列项在几十行之后被 `plan.drop` 静默丢掉）。

通知说了一件不会发生的事。

## 怎么撞上的

MOB-40 之前的缺陷让整库 254 张都传上去了，用户只想要其中 11 张。清理那
243 张范围外的照片时，每一轮校准都会命中这条路径。

## 修法

通知要发在「**确认要重传**」之后，不是「发现丢了」之后。把
`calibrateIfReachable` 的通知回调拆出来：入队照旧（那是 MOB-34 的语义，
不动），`lost` 集合带回调用方，等 `plan` 算完、`plan.drop` 除掉之后，
只对**真的会重传的那些**发通知。

## 不准动

- MOB-34 的入队语义（发现即入队，队列是权威，通知只是提醒）
- MOB-37 的「先落盘、再通知、吞异常」三条顺序
