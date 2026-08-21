# MOB-31 选了 12 张的相册，进度条显示 186 张　级别 L2

> ⛔ 未实施。**机制未查明**——现场证据已被 WorkManager 清掉，本卡的首要任务
> 是**先加可观测性**，不是猜。

## 用户报告（2026-08-21）

「我勾选了一个相册，那个相册只有12个文件，结果进度条显示备份186张！！！」

## 已核实的事实

| 事实 | 证据 |
|---|---|
| 选中的相册确实只有 12 张 | `content query ... where bucket_id=-1033401746` → **12** |
| 相册范围**保存正确** | `backup_scope.xml`: `bucket_ids=-1033401746`（11:18 写入） |
| 扫描确实**只扫了选中相册** | 存储端 11:19:11 `ingest.new = 12`，一张不多 |
| 成功那次 run 的输出就是 12 | WorkManager `WorkSpec.output` 解码：`ppass.backup.ingested = 12` |
| 那一次是**重试** | `ppass-catchup-backup` `run_attempt_count = 1`，11:18 有两条 `backup.started` |
| `186` 这个数**真实存在于手机状态里** | `confirmed.json` 的 `bucketOf`：**186 条属于相册 `-1739773001`**（见 MOB-29） |

**所以传输是对的，186 是个显示问题。** 而 186 恰好等于 MOB-29 里那批陈旧
「已备份」记录的条数——两条卡很可能同源。

## 为什么查不下去

`WorkProgress` 表在 work 完成时会被清空，**用户看到的那个进度数据已经不存在了**。
`ppass-catchup-backup` 的第一次尝试（被重试掉的那次）读到的 `bucketIds` 是什么、
`scan.items.size` 是多少，现在无法还原。

⚠️ **不许在卡里写一个「大概是因为…」的机制然后照着改。** 上一轮 WATCH-02 我
列了三条「最可能」的假设，三条全错，根因是一个斜杠。

## 第一步：加可观测性（本卡真正要做的）

BackupWorker 每次运行开始时打一条结构化日志，至少包含：

```
bucketIds（或 null=全量）、since(watermark)、fullRescan、scan.items.size、
triplet 的 N/M/K、run_attempt_count
```

现在 `BackupWorker` 只在跳过坏记录时 `Log.w`（`BackupWorker.kt:465`），
正常路径**一行日志都没有**，真机上什么都看不见。

## 第二个怀疑点（顺手核）

`MainActivity.kt:654-670`：保存相册范围后立刻 `triggerUserPresentBackup`。
`refreshTriplet()` 只在 init / WorkInfo 流变化时跑，**`saveScope` 之后没有
显式刷新**。所以「改完相册返回首页」那一刻，英雄卡上的 M/N 可能还是**旧范围**
的数字——旧范围如果是那个 186 张的相机相册，屏幕上就是 186。

这条能解释用户看到的现象，但**没有直接证据**，必须先复现。

## 验收要求

- 先加日志，再复现：换相册 → 抓日志 → 确认屏幕上的数字来自哪个口径
- 定位后再改，改完必须带反证
- 真机：选一个 12 张的相册，进度条与三元组分母都必须是 12
