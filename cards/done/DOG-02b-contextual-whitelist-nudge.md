# DOG-02b 契机式白名单提醒　级别 L1

## 语义基准

decisions ④：常驻引导卡片保留；新增**该跑没跑成才提醒**。

## 修法

- 数据源：BackupAttemptStore/任务执行记录——判定「近 N 天（建议 2）
  存在应触发的自动备份但均未成功执行」且当前未加白名单。
- 满足即通知一次：「昨晚没备份成，可能是系统限制了后台——加入电池
  白名单可以避免」，点开落白名单引导（DOG-02 现有回退链）。
- 加白后/成功一轮后状态清零；通知去重窗口 ≥72h。
- 判定纯函数化（与 SENT-01 同套路，别耦合）。

## 可执行验收

1. 单测：判定边界（未加白+连续未跑成→报；已加白不报；跑成过不报；
   去重窗口）。
2. 集成：mock 条件满足 → 通知一次、点开到引导（贴输出/截图）。
3. 反证：把「未加白」条件去掉 → 已加白用户被骚扰（测试红，贴输出后还原）。
4. android 全量绿。

## 收尾
CI 绿；文档三件套；卡移 done/。

---

## 验收记录（2026-08-12 Salamira）

**实现**：
- 新增 `backup/WhitelistNudgeStore.kt`：独立 store（lastFailedAt /
  lastSuccessAt / lastNudgedAt，filesDir/whitelist-nudge.json，tmp+rename
  崩溃安全）；`shouldNudgeWhitelist` 判定纯函数（JVM 可测）：①未加白
  ②有失败记录 ③最近失败 ≤2 天 ④失败后无成功（当前处于连续没跑成态）
  ⑤距上次提醒 >72h。
- BackupWorker 搭便车：成功一轮（含 scan 空早退）recordSuccess 清零；
  失败尝试 recordFailure；finally 统一 maybeNudgeWhitelist（复用 UX-02
  通道 + 独立 id 2029，通知进 App 见 DOG-02 现有 Home 引导条）。
- i18n：2 个新 key en/zh 对称。

**验证**：
- WhitelistNudgeStoreTest 11 项（判定边界：未加白+近期失败报/已加白不报/
  无失败不报/失败超窗不报/2 天边界报/失败后成功不报/去重窗口内不重复/
  过窗再报；store 往返/通知持久化/损坏当空）。
- android 全量 **161/161 绿**（含新增 11 项）。

**真机待验（C 线挂账）**：
1. mock 条件满足 → 通知一次、点开到 Home 引导（截图）。
2. 加白后/成功一轮后不再通知（模拟器贴输出）。
