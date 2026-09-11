# MOB-69 REBUILD-04 删除的通知发送端未接回：哨兵/白名单/重传三条（L2）

> ⬜ 状态：未开工（2026-09-11 由 MOB-67 排查时开）
> 级别：**L2** · 阻塞：无

## 问题

MOB-67 的根因考古发现：REBUILD-04 生产切换（commit `a325208`，
BackupWorker 降级为纯 wake adapter、删 1124 行）把**四条**系统通知的发送端
一起删了。失败通知（id 2027）已由 MOB-67 接回，其余三条至今没有生产调用点
（2026-09-11 源码核实：判定/落盘逻辑全在，发送端零命中）：

| 通知 | 原 id | 判定逻辑现状 | 后果 |
|---|---|---|---|
| SENT-01 哨兵「3 天没连上电脑了——照片没丢」 | 2028 | `shouldNotifySentinel`/`markNotified` 零生产调用 | 电脑长期离线，手机用户完全无感 |
| DOG-02b 契机式白名单提醒「昨晚的备份没跑成」 | 2029 | `WhitelistNudgeStore` 零生产调用 | ROM 冻结后台后无引导 |
| MOB-29/37 重传告知的系统通知腿 | 2030 | `noteReuploadNotice` 零生产调用（App 内可见腿同样断：UI-10 已把数据源换成账本 `NEEDS_DECISION`，但落盘登记 `ReuploadNoticePrefs.record` 无生产写入方） | 「照片被传回来」用户不知情 |

字符串资源（`notif_sentinel_*`、`notif_whitelist_*`）全部还在 en/zh 字典里，
ROADMAP 里这三条都记的是 merged——**文档与代码已经漂移**，这是批次删除时
没有通知面清单核对的直接代价。

## 期望行为

三条通知在 Flow 生产路径上各有一个明确的接线点，恢复被删前的语义
（判定条件、去重窗口、固定 id 折叠均不变）；或用户拍板某条在新架构下
不再需要，那就连同字典字符串与 ROADMAP 状态一起显式下线，不许静默悬空。

## 验收标准

- [ ] 先逐条定性：每条在新 Flow 架构下是否仍是需要的产品行为（哨兵的
      「可达性」事实来源、白名单提醒的触发时机都随 REBUILD 变了）——
      需要 vs 下线的裁决写进本卡，需要接线的部分才继续往下。
- [ ] 接线的每条：JVM 测试证明判定跃迁→通知发送被调用一次、去重窗口内
      第二次不触发；反证（去掉判定条件用例变红）。
- [ ] 真机：三星触发各条条件（哨兵=mock 全失败跨阈值），通知恰好一条、
      点开进 App。
- [ ] `grep -rn "noteReuploadNotice\|shouldNotifySentinel\|WhitelistNudgeStore"
      apps/android/app/src/main/java` 不再出现「只有定义没有调用」的悬空。

## 范围

- 只准动：`apps/android/app/src/main/java/.../backup/`（三条判定逻辑的
  Flow 侧接线点）、`backup/flow/`（触发时机）、对应 JVM 测试、
  ROADMAP 对应条目状态行。
- 不准动：MOB-67 已接好的失败通知链路；Home 红卡渲染；
  AUDIT 管线。

## 阻塞与依赖

无。MOB-67 已验证接线模式（`FailureNotifier` 边界 + 固定 id + runCatching
吞发送异常），本卡复用该模式，不重造通知基础设施。

---

## 备注

来源：2026-09-11 MOB-67 根因考古。哨兵与白名单提醒的原实现搭的是旧
WorkManager 后台任务「便车」（搭车记可达性/校准），便车没了乘客要重新找车——
所以第一条验收是定性而不是照搬接线。
