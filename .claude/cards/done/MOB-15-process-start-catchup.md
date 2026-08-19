# MOB-15 进程启动补捞——通知丢失后无人接手的最后一环　级别 L2

**用户定调**（2026-08-19）："我肯定是需要 kill app 的啊，配置好了谁整天
看你这个同步备份用的 app？"

## 为什么 MOB-14 的修法不够

MOB-14 把「打开 App 无条件补跑」做出来了，但用户一句话点破：**这个 App
就该配完扔那儿，用户根本不会打开**。把后台可靠性问题修成「要用户手动
救场」，方向就是错的。

## 真正的机会窗口

MOB-14 的真机时间线里有一行被浪费了：

```
10:39:50  用户从最近任务划掉 App，进程被杀
10:40:07~09 拍照 → 通知落在窗口里，无人接收
10:40:18  Start proc 29137 for SystemJobService     ← 进程活了！
10:44:30  直到下一个触发事件到来才传完
```

10:40:18 进程已经被系统拉起来了，却只做了「重排 job」一件事——**完全
有能力顺手扫一遍相册**，白白等了 4 分钟。

## 改动

新增 `PPassApplication : Application`（manifest 注册），`onCreate` 里：
未配对 / 已暂停直接返回，否则 `triggerProcessStartCatchup(this)`。

进程因**任何**原因被拉起都会经过 `Application.onCreate`——系统拉起执行
work、用户点图标、其它组件唤醒，全都覆盖。

`triggerProcessStartCatchup` 用**后台档**约束（进程被系统拉起 ≠ 人在
操作，不该享受用户在场档的电量豁免）+ 独立 unique name +
`ExistingWorkPolicy.KEEP`（同进程生命周期内重复调用不叠加）。

### 它同时也是「条件状态转移」的触发器

用户同一轮提的另一个要求：「条件发生状态转移的时候，需要有一个重新
触发的逻辑」。这条**不需要**自己注册 NetworkCallback——一个带约束的
pending work 本身就是条件转移触发器：约束不满足时 job 挂起，由系统
统一监听条件变化并唤醒（这也是最省电的做法）。

所以本卡排的这个 work：条件满足就立刻跑；不满足就挂起等，Wi-Fi 一
连上、电量一恢复就自动执行。

**原来的漏洞从来不是「条件转移没人管」，而是「通知丢了，压根没有
work 在等条件」**——本卡补的正是这一环。

## 暂停态的第二道闸

进程启动补捞会在冷启时 enqueue，所以 `doWork` 内部补了一条
`if (AutoBackupPrefs(ctx.filesDir).paused()) return Result.success()`，
`pauseAutoBackup` 也一并取消该通道。否则 UX-06 的「暂停」会被进程重启
绕过。

## 验证

- `:app:testDebugUnitTest --rerun-tasks` **186/186 绿**，新增
  `process_start_catchup_is_wired_in_application`、
  `paused_state_blocks_every_channel`。
- **反证**：注释掉 `triggerProcessStartCatchup(this)` → 测试红。
- 真机：`force-stop` 后冷启，两个 BackupWorker 同时起来（Application 的
  补捞 + Activity 的用户在场档），均 SUCCESS。

## ⚠️ 测试质量事故（本轮发现，已修）

反证第一次跑**没红**。原因：源码级断言写成
`src.contains("triggerProcessStartCatchup(this)")`——把那行代码注释掉，
字符串照样在文件里，断言依旧通过。**这种断言拦不住回归，是假绿。**

已抽出 `codeOf(file)` 辅助函数，读源码时先 `filterNot { 以 // 开头 }`
剥掉注释行，本文件所有源码级断言统一走这条路。重跑反证确认变红。

教训：源码级断言必须剥注释；**每条新断言都要真的跑一次反证**，不能
凭"应该会红"下结论。

## 遗留（未做）

周期兜底仍是 6h。若进程长时间不被拉起、又没有 pending work 在等条件，
最坏要等 6 小时。建议缩短到 1h 或 30min（周期任务本身带约束，条件不
满足时会挂起等待，是最后一道条件转移触发器；扫描为空时代价极小）。
待用户拍板。
