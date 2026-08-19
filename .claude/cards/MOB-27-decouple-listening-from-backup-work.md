# MOB-27 把「监听」和「干活」拆开——监听空窗与备份时长解耦　级别 L2

**状态**：方案已议定、**未实施**。2026-08-19 用户要求整理成文，下个
session 接着讨论或直接做。

---

## 一、先看清现在的整条链路

### 四个触发事件（MOB-02 定的模型，仍然有效）

| # | 事件 | 谁发起 | 依赖 App 活着？ |
|---|---|---|---|
| ① | 选完/改完相册返回 | MainActivity | 是（用户操作本身） |
| ② | **新照片落库** | 系统 JobScheduler（content trigger） | **否** |
| ③ | 周期兜底 5h | 系统 JobScheduler（periodic） | **否** |
| ④ | 打开 App | MainActivity | 是（用户操作本身） |
| ⑤ | 进程被任何原因拉起 | `PPassApplication.onCreate` | **否** |
| ⑥ | 每轮备份跑完重挂监听 | `BackupWorker.finally` → rearm | **否** |

②是主路径，③⑤⑥是保证它不失效的配套。

### 条件不满足时的行为（这块是对的，别动）

约束目前两条：**电量不低**（硬约束）+ **仅 Wi-Fi**（用户可关）。
条件不满足时 job **挂起等待**，由系统监听条件变化并唤醒——不需要我们
自己注册 NetworkCallback，也不需要进程活着。实测：断网拍两张 → 恢复
Wi-Fi → 同一个 job 一次性把两张都捞走（`offered=2`）。

**"条件转移要重新触发"这件事是系统内建的，前提是有一个挂起的 job 在等。**
真正的漏洞从来不是"条件转移没人管"，而是"通知丢了，压根没有 job 在等"。

---

## 二、核心问题：监听 work 和干活 work 是同一个

```
content trigger job（带 URI 监听 + 约束）
   ↓ 触发。**监听在这一刻就被消耗掉了**
BackupWorker.doWork()      ← 扫描 + 哈希 + 上传，可能几分钟
   ↓ 完成
finally → enqueueContentTriggerRearm(延迟 REARM_INITIAL_DELAY_SECONDS)
   ↓
ContentTriggerRearmWorker → 等上一轮落终态 → REPLACE 重挂监听

监听空窗 = 整个备份时长 + 重挂延迟
```

用户 2026-08-19 实测复现："连拍出问题了，中间出现一次上传，之后就没有
了……大概十几张，中间我稍微停顿了下，前面的出去了，后面的就没有同步。"
——前几张触发了备份，之后拍的那些**没有任何监听在接**，通知就丢了。

（那批照片并没有丢：水位没推过它们，下一个触发事件会扫到。但用户体感
就是"没同步"。）

## 三、当轮已做的缓解（治标，已合并）

1. `REARM_INITIAL_DELAY_SECONDS` 15s → **1s**，`REARM_WAIT_TICK_MS`
   2s → **500ms**。
2. rearm 重挂后**按需补捞一次**：`enqueueContentTriggerRearm(ctx,
   catchUp = batchSize > 0)`，rearm 里读 `KEY_REARM_CATCH_UP` 决定是否
   `triggerProcessStartCatchup`。只在上一轮确实有照片时补，否则会变成
   「补捞 → 空扫描 → 又排 rearm → 再补捞」的无限循环；有照片才补 ⇒
   连拍场景一轮轮收敛，扫空即止。

**用户当场指出这只是治标**（原话）："你强行用时间来做判断的话，是不太
合适的。假设你重挂超过了 1 秒或者 2 秒，那中间还是会存在 gap。"
——完全正确：gap 的长度取决于 work 执行多久，不是调常量能控制的。备份
跑 3 分钟，gap 就是 3 分钟；那两个常量只影响最后 1 秒。

## 四、议定方案：拆开监听与干活

```
content trigger job
   ↓ 触发
ContentTriggerWorker       ← 新增，只做两件事，毫秒级返回：
   1. enqueue 一个独立的备份 work（异步跑，不占监听）
   2. enqueue rearm
   ↓ 立即完成
rearm → 重挂监听

监听空窗 ≈ 1 秒（**恒定，与备份时长无关**）
```

要点：
- content trigger 绑定的 Worker 从 `BackupWorker` 换成新的
  `ContentTriggerWorker`；`buildContentTriggerRequest` 相应改。
- 真正的备份走独立 unique name（可复用
  `PROCESS_CATCHUP_WORK_NAME` 那条通道，或新开一条），跑多久都不影响监听。
- 补捞机制保留，降级为兜底——只覆盖那 ~1 秒，不再是主力。

### 还能不能把这 1 秒也干掉

能：**两个交替的 unique name**（A 触发时挂 B、B 触发时挂 A）。名字不同
就不存在"REPLACE 掉正在跑的自己"这个坑，gap 可接近 0。代价是要维护
A/B 交替状态，复杂度明显上一档。

**建议顺序**：先做解耦（gap：备份时长 → 恒定 ~1s），实测连拍确认那 1 秒
到底漏不漏；漏才上交替 name。**别跳过实测直接上复杂方案。**

## 五、为什么 rearm 必须留一点延迟，不能设 0

rearm 走 `ExistingWorkPolicy.REPLACE`。若在 content trigger work 还
RUNNING 时动手，会**取消掉正在传照片的自己**——这是 MOB-08 踩过的坑，
现象是凭空冒出 `JobCancellationException`。所以 rearm 内部先轮询等它落
终态才 REPLACE，`REARM_INITIAL_DELAY_SECONDS` 不许归零（有测试锁死）。

拆开之后这个约束仍在，但因为 `ContentTriggerWorker` 毫秒级返回，等待
几乎立刻满足。

## 六、可执行验收

- 单测：锁死 content trigger 绑定的是 `ContentTriggerWorker` 而非
  `BackupWorker`；锁死它只派活不干活（不出现扫描/上传调用）。
  **反证**：改回绑 `BackupWorker` → 必红。
- **真机连拍实测**（这条不能省，当轮就是靠它发现问题的）：连拍 15~20 张，
  中间故意停顿一下，期望**全部**送达电脑端，且日志里不出现"前一批传完
  后面再无动静"。对照数据见当轮：`offered=8 pushed=8` 之后连续几轮空扫描。
- 源码级断言一律先剥注释再判断（`codeOf()`）——直接 `contains` 会被
  「把代码注释掉」骗过去，当轮踩过两次假绿。

## 七、范围

只准动 `backup/BackupWorker.kt`（拆出新 Worker）及其单测。**不要动**
约束模型（MOB-10 的 batteryNotLow）、周期间隔（MOB-17 的 5h）、
补捞与 Application 接线（MOB-15/16）。

## 八、下个 session 若要先讨论，争议点在这

1. 独立备份 work 用**新 unique name** 还是复用 `PROCESS_CATCHUP_WORK_NAME`？
   复用省事，但 KEEP 语义下可能被正在跑的补捞挡住，导致这次触发被吞。
2. 解耦之后，补捞（`catchUp = batchSize > 0`）还要不要留？gap 只剩 1 秒
   的话它的价值下降，但删掉就没有兜底了。
3. 交替 name 现在做还是等实测？（建议等）
