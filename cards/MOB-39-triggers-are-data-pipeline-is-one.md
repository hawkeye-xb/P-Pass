# MOB-39 触发层抽象：触发是数据，管线只有一条　级别 L1

> ⬜ 状态：未开工
> 级别：L1 · 阻塞：无（但**排在 `MOB-38` 之后**，理由见「阻塞与依赖」）

## 问题

**不是「触发路径不够」，是「每条路径各自手写」。** 现有 7 个入口，每个都自己
决定 unique name、约束档、重复触发策略、要不要全量重扫：

| 入口 | unique name | 约束档 | 重复触发策略 | 其它 |
|---|---|---|---|---|
| `dispatchWatchBackup`（监听派活） | `ppass-media-watch-backup` | BACKGROUND | APPEND_OR_REPLACE | |
| `triggerUserPresentBackup` | `ppass-catchup-backup` | USER_PRESENT | KEEP | |
| `triggerProcessStartCatchup` | `ppass-process-catchup` | BACKGROUND | KEEP | |
| `triggerManualBackup` | `ppass-manual-backup` | MANUAL（零约束） | KEEP | `KEY_FULL_RESCAN` |
| `scheduleAutoBackup`（周期 5h） | `ppass-auto-backup` | BACKGROUND | UPDATE | periodic |
| `rescheduleAutoBackup`（设置变更） | 同上 | BACKGROUND | REPLACE | |
| `resumeAfterInterruption` | 复用前台补捞 | — | — | 清中断标志 + 重挂监听 |

### 这个形状直接产出了最近五个 bug，全是「漏接一处」

| 卡 | 漏在哪 |
|---|---|
| `MOB-33` | 暂停只认识 5 个 name 里的 1 个 → 对自动备份完全无效 |
| `MOB-33` | 进度条按 tag 观察全部 name，但选取用 `firstOrNull` → 两条同时跑就乱跳 |
| `MOB-38` | 前台补捞漏了 `ON_RESUME` 这个时机（只挂在一次性的 `LaunchedEffect` 上） |
| `MOB-34` | 定向补偿漏接一处校准门（`BackupUiStateHolder` 那条） |
| `MOB-35` | 监听重挂漏了 `doWork` 的 `finally` 那处门控，MOB-28 红线一度被破 |

五个都是同一句话：**新增或修改一个触发时，忘了同步另一处。** 只要「触发」是
散落的代码路径而不是统一的数据，这类 bug 就会结构性地继续发生。

### 验收人给的抽象（2026-08-26，本卡的全部依据）

> 「按道理，触发方式是不同的抽象工厂，拉起对比传输是固定的管道，不管谁触发，
> 都走到这里来。触发 - 上传。上传的流程又有它固定的方式，比如 check hash，
> 队列准备，多次触发的处理等等。」

## 期望的形状

**触发 = 数据；管线 = 一条，固定。**

```
Trigger(kind)                       ← 唯一的入口类型，调用方只说「因为什么」
  kind: Watch | UserPresent | ProcessStart | Manual | Periodic | Resume
  约束档     由 kind 推导            ← 不再每处手填 BackupTier
  fullRescan 由 kind 推导            ← 只有 Manual 为 true
  unique name 由 kind 推导（或收敛成一个）

enqueue(trigger)                     ← 唯一的入队函数
        │
        ▼
管线（一条，固定顺序）
  ① 抢门        backupInFlight —— 「多次触发」在这里统一收敛
  ② 校准        existCheck → lost → 告知落盘 + 定向补偿入队
  ③ 候选构建    水位扫描 + 范围补齐 + 重传补偿 → plan.items
  ④ 哈希        HashCache 命中优先
  ⑤ 传输        offer → push → commit
  ⑥ 收尾        confirmed 落盘 + 水位推进 + 通知
```

**核心那一条：「多次触发怎么处理」不该由每个触发方各自选 KEEP/REPLACE，
而该由管线入口的门统一收敛。** `MOB-33` 的 `backupInFlight` 已经做了这一半
（门在管线入口，所有触发都撞它）。本卡做另一半：**unique name 收敛**，
于是暂停、进度、取消都只对一个目标，`firstOrNull` 那类问题结构上不存在。

**可行性**：name 隔离原本是为了「暂停手动不影响自动」，而 `MOB-33` 已经把暂停
改成**按 id 取消正在跑的那条**，不再依赖 name 隔离。所以合并没有阻碍。

## 验收标准

- [ ] 单测：新增一个 `kind` **只需改一处**——判据是「`kind` 的枚举与它的约束档/
      fullRescan/name 的映射在同一个地方，且有一条测试遍历全部 kind 断言映射齐全」
      （少填一个 kind 就红，这正是防「漏接一处」）
- [ ] 单测：全部 6 个 kind 都能入队并抵达管线（参数化，不是抽查）
- [ ] 单测：unique name 收敛后，**暂停仍然按 id 取消正在跑的那条**（`MOB-33`
      的红线不许回退）；进度选取仍确定性（`runningInfoOf`）
- [ ] 单测：`Manual` 的两条专属语义不丢——零约束 + 全量重扫
- [ ] 单测：`Resume` 仍是**唯一**允许重挂后台监听的 kind（`MOB-28` 红线）
- [ ] 反证：去掉「kind → 约束档」的集中映射、改回每处手填 → 遍历测试变红
- [ ] 全量回归：Android 全量单测保持全绿（本卡是重构，**不许改任何既有语义**）
- [ ] 真机：六种触发各走一遍，行为与重构前一致（尤其手动的零约束、监听的 1-2 秒）

## 范围

- 只准动：`apps/android/.../backup/` 的触发层（入队函数、unique name、约束档
  映射）与调用点；相关测试
- **不准动任何既有语义**：`MOB-19` 一条管线、`MOB-33` 的互斥门与按 id 暂停、
  `MOB-28` 的唯一重挂入口、`MOB-09` 的坏记录跳过、`MOB-17` 的 5h 周期、
  `MOB-34/36/37` 的补偿与告知
- 不准动：`crates/`、桌面端

## 阻塞与依赖

**排在 `MOB-38` 之后。** 理由：`MOB-38` 是 L0（用户实际撞到的前台不同步），
重构与修 bug 混在一起出了问题分不清是谁的。先修 bug、再动结构。

⚠️ 依赖 `MOB-33` 已落地（0.4.0-test.5）——互斥门是「多次触发在管线入口收敛」
这条设计的前提，没有它 name 收敛会退化成「所有触发互相 KEEP 掉」。

---

## 备注

### 顺带看一眼这条日志

真机日志（2026-08-26，10 分钟内 5 次）：

```
W/JobScheduler: Job didn't exist in JobStore: … MediaWatchJob
```

看门 job 用「同 id 重新 schedule」代替 `jobFinished()`（javadoc 明确允许的写法，
`MediaWatchJob` 的注释里引了原文），这个警告是那个竞态的副产物。**大概率无害**
——备份该跑的都跑了（同段日志里有三次 `offered=1 pushed=1 ingested=1`）。
但 5 次/10 分钟不算低，name 收敛之后这条路径会简单一截，**顺手复核一下，
别单独开卡**。

### 这张卡的收益怎么衡量

不是「代码更漂亮」。是：**新增一个触发时机从「手写一套 name + 约束 + 策略，
还得记得同步暂停和进度那两处」变成「加一个 kind」。** `MOB-38` 那类 bug 会从
「每次新增触发都可能再犯」变成「结构上不可能」。
