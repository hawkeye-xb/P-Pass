# MOB-29 库里删掉的照片会被传回来且用户不知情；「已备份」在两次备份之间是谎话　级别 L1

> 🟡 状态：代码已合并（commit 95f3c4f），等真机验收
> 级别：L1 · 阻塞：无（2026-08-25 方向已定，墓碑方案撤销，无待拍板项）

## 问题

### ① 删掉的会被传回来，而且用户完全不知道发生了什么（用户报的）

存储端算「手机还缺什么」只看索引。库里删了 → 索引没了 → 下一轮
`manifest` 报「缺」→ 手机重传。**照片回来这件事本身是对的**（见「用户定调」），
问题是**全程静默**：用户删了、照片回来了、没有任何一端说过一句话。

### ② 「已备份」在两次备份之间是谎话（同源）

实测（2026-08-21，用户三星 SM-S9210 + 本机库）：

```
手机说已备份:  188 张
库里真有    :    3 张
库里没有    :  185 张   ← 手机在撒谎
```

那 185 条来自 8/20 那轮全量备份（存储端审计佐证 `ingest.new = 186`），
用户后来在 Finder 里删光（当时 WATCH-02 还没修），随后清库重装。
**手机从此一直显示那 186 张「已备份」，而世界上任何地方都没有它们。**

纠正机制**存在且有效**——`calibrateIfReachable` → `existCheck`（把已确认
hash 发给存储端问「你还有吗」）→ `removeMissing`。强制跑一次备份 job 后
`confirmed` **188 → 3，且 3 张全部真在库里**。

**缺陷是：校准只在备份开始时才跑**（`BackupWorker.kt:418`，在 `doWork` 里）。
两次备份之间不管存储端发生什么（用户删照片、库被换掉、磁盘坏了、换台电脑），
手机上那个大数字一动不动——而它是用户判断「我的照片安不安全」的唯一依据。
**用户不拍照就可能好几天不校准。**

## 用户定调

### 2026-08-25（现行）

> 「我们作为存储端就不应该丢数据。……我手机上的图片同步回去之后，我就在手机
> 删掉了，然后它在备份端挑选出了不要的，删掉也是很 OK 的。但是如果我手机
> 没删，它在存储端删了，自动补回去也是很正确的，只不过这个逻辑或者是状态
> 需要让用户知道。」

> 「我们设计的就是，如果你想要在服务端删除这个事，你先在移动端删除了，再去
> 删服务端的……这样能明确表示这张照片是不需要了的，因为你执行了两次删除。」

> 「不用这么复杂吧……我们可以提示它一句：『资源在客户端丢失，正在重传。如果是
> 主动删除，请先删除移动端的数据。』……我们不需要很明确的，因为它的范围只在
> 那一点，就是让用户知道我们默认去做了这个事情就行。」

**定调三条**：
1. **重传是正确行为，不拦。** 存储端不该丢数据，补回来是对的。
2. **删除的正确姿势是「先删手机原图、再删库」**——两次删除表达意图，
   源被消灭，重传自然不发生。**不需要任何「记住我不要它」的状态。**
3. **要做的只是让用户知道**，而且**不做精确归因**（换库概率低，大部分是人删；
   一句带条件从句的话在两种成因下都成立）。

### 2026-08-21（已被上条覆盖，保留供对照）

> 「如果在客户端删除掉手机备份的某一部分内容，我们在客户端挂一个常驻提示……
> 或者禁止这个设备再往文件里备份。」

当时的方向是**墓碑**（库里删掉的 hash 记一笔，`manifest` 算 `missing` 时排除）。
**2026-08-25 整条撤销**，理由见「备注／为什么不做墓碑」。

## 期望行为

- **重传照旧发生**，不引入墓碑、不引入排除列表、不改 `missing` 语义。
- **删除发生地（桌面端）给警告**：用户在 Finder 里删了来自某设备的照片时，
  告诉他会被传回来，以及想真删该怎么做（先删手机原图）。
  警告只针对 **delete**——add / move 对我们影响为零（见备注），不警告。
- **手机端给一句话**：校准发现「我确认过的照片库里没有了」时提示
  「资源在客户端丢失，正在重传。如果是主动删除，请先删除移动端的数据。」
  **不区分成因**（人删 vs 换库），措辞在两种情况下都成立。
- **「已备份」数字不再在两次备份之间说谎**：校准不再只在备份开始时跑。

## 验收标准

- [x] 集成（daemon）：库里删掉一条设备来源的资产 → 审计出现
  `asset.removed_external`，且**下一轮 `manifest` 里该 hash 仍在 `missing`**
  （确认「不拦重传」这条定调被真的实现，不是顺手做成了墓碑）
- [x] 单测（android）：`confirmed` 里有、`existCheck` 说缺 → 触发提示一次；
  同一批 hash 下一轮**不再**触发（`removeMissing` 已剔除，自然一次性）
- [x] 单测（android）：**新照片**（不在 `confirmed`）和**传输失败的照片**
  （commit 未成功，从未进 `confirmed`）**都不触发**提示
- [x] 反证：去掉 `confirmed` 交集条件（改成对全部 missing 提示）→ 上一条变红
- [x] 单测（android）：校准脱离「备份开始」也能跑（搭背景便车），且
  daemon 不可达时保留缓存不清零
- [ ] 真机：复现本卡开头那组数字比对，改后「库里没有 = 0」；在 Finder 里
  删若干张 → 桌面端出现警告 + 手机端出现那句提示 + 照片确实被传回来

## 范围

- 只准动：
  - `apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/`
    （`calibrateIfReachable` 的插入点 + 校准调度搭背景便车）
  - 桌面端警告的呈现（`asset.removed_external` 已有审计，只做呈现）
- 不准动：
  - **`manifest` / `missing` 的计算逻辑**——本卡明确不拦重传
  - `proto`（**不加字段**。用户 2026-08-25：「加字段的话，它侵入太多了，
    单一性不够强」）
  - 废纸篓恢复造成的多余副本——**系统与用户的行为，本卡不处理**
    （用户 2026-08-25：「有替换的这个提示就行，这个系统行为我们就不多做处理了」）

## 阻塞与依赖

无。方向已定，无待拍板项，可直接开工。

现成抓手（均已核实存在）：
- `crates/daemon/src/reconcile.rs:111` 外部删除 → `delete_asset` +
  `asset.removed_external` 审计（WATCH-02 那批）
- `BackupWorker.kt:770-772` 校准算出 `missing` 后紧接 `removeMissing`
  ——提示的插入点就是这里
- `BackupWorker.kt:521` `confirmedStore.recordRun` 在 commit 成功后才写
  ——所以 `confirmed` 是「拿到过 commit 确认」的硬证据
- UX-02 通知通道；SENT-01 的背景便车（校准可搭同一趟）

---

## 备注

### 为什么不做墓碑（2026-08-25 撤销记录）

原方案是「库里删掉的 hash 记进墓碑表，`manifest` 算 `missing` 时排除」，
并因此**被迫**配一个「从设备重新取回全部照片」的逃生口（否则墓碑会连带
挡住「库真丢了数据要从手机恢复」这条路）。

撤销理由：

1. **墓碑存在的唯一目的是拦住重传**，而定调已改为「重传是正确的」——
   目的消失，机制随之消失。
2. **一个需要配「恢复」按钮的机制，说明它自己制造了它要解决的问题。**
3. **真正消灭重传的只有消灭源**：手机上原图还在，存储端就一定算出「缺」。
   「先删手机、再删库」的顺序规则直接消灭源，代价只有「顺序反了会回来」
   ——那正好由本卡的提示来教。
4. **内置垃圾桶同样不做**：库就是普通的访达文件夹，删除走 macOS 废纸篓，
   恢复用访达「放回原处」。自建垃圾桶等于跟系统垃圾桶打对台，用户要在
   两个地方找同一张照片。

### 为什么警告只针对 delete

| 访达操作 | 对我们的影响 | 态度 |
|---|---|---|
| 往库里 **add** | 零——被收录，按用户摆的位置采纳（`rel_inside_originals`） | 鼓励，WATCH-04 定调不变 |
| 库里 **move** | 零——按 hash 重新认领（`asset.relocated`） | 随便挪 |
| 从库里 **delete** | **有**——会被传回来 | **警告，引导从源头删** |

WATCH-04「访达是布局的主人」不受影响：本卡不劝用户远离 Finder，
只在**唯一有代价的那个动作**上给警告。

### 竞品对照（2026-08-25 调研）

Immich 架构同源（手机算 checksum 问服务端「你有没有」），**同病且未解**：
`#4282` → `#22507` → `#23897` 三年间同一个问题反复被提。其回收站事实上是
一个 30 天隐式墓碑（软删只写 `deletedAt`，checksum 行还在 → 挡住重传；
**清空回收站的瞬间照片就回来**）。Immich 主维护者 alextran1502 明确反对
隐式 hash registry（「Deleted is not one event」，五条代码路径各有意图），
偏好显式追问用户是否连本地副本一起删——与本卡定调同向。
Google Photos / Nextcloud 同病。全行业无干净解。

**我们比 Immich 好的一点**（不是抄来的，是趋同后的差异）：Immich 的去重
**按 library 分、不是全局的**，所以「照片在 external library 里明明有，
把 upload library 那份删了」照样重传。我们只有一个库、一个索引、一张全局
hash 表，这个坑不存在；「只想把照片挪个位置」那类诉求在我们这儿也不成立
（move 不触发重传）。

### 一条已知边界（如实记录，本卡不做）

提示**不是拦截点**。校准与重传发生在同一次 session 内
（`calibrateIfReachable` 在 `doWork` 开头，紧接着同一轮就 re-offer），
中间没有让用户来得及反应的窗口。提示是事后解释 + 教学。做成「拦住问一下」
需要把备份拆成两阶段，是另一个量级的改动，不在本卡范围。

### 开发期噪音提醒

清库重装是开发/测试期最常做的动作，每次都会触发那句「资源在客户端丢失，
正在重传」。这是**预期行为**（措辞在换库场景下同样成立），不是 bug。

## 实施记录（2026-08-25，commit 95f3c4f）

### 改了哪几处

| 处 | 改动 | 为什么 |
|---|---|---|
| `apps/android/.../backup/Calibration.kt`（新） | 校准内核 `calibrateConfirmed(store, existCheck, onLost)` + 判据 `lostFromLibrary(confirmed, missing)` | 判定与接线分家：判据是纯函数，JVM 单测直接跑，反证靶就在这里 |
| `apps/android/.../backup/BackupWorker.kt` | `calibrateIfReachable` 改成薄接线（exist-check 走真连接、`onLost` 发通知）；新增 `postReuploadNotification`（UX-02 通道，固定 id 2030）；`doWork` 的 finally 里补一次 `calibrateTail` | 提示插在 `removeMissing` **之前**（顺序承重）；固定 id 让并发双发折叠成一条；补校准让校准不再继承备份管线的前置闸门 |
| `apps/desktop/src/lib/externalDelete.js`（新）+ `App.svelte` | 审计流 → 警告判据（只认 `asset.removed_external`）+ 总览页一条警告 | 删除发生在电脑上，警告就出在电脑上；后端零改动，只消费既有审计 |
| `assets/i18n/{en,zh}.json` + `crates/diag/src/keys.rs` + Android 捆绑副本 | 4 个 key（手机端两句 + 桌面端警告/知道了），`ALL.len()` 95→99 | 文案进字典是仓库惯例；四文件锁步，漂移由 `DiagTextTest` 守 |
| `crates/daemon/tests/sync_flow.rs` | 新增 `deleted_asset_is_still_reported_missing_no_tombstone` | **反墓碑判据**：删掉的 hash 下一轮仍在 `missing`。daemon 生产代码零改动 |

### 与卡面的一处诚实差异

卡里写「校准只在备份开始时才跑……用户不拍照就可能好几天不校准」。按代码
实况，**周期兜底任务（5h）本身就会跑 `calibrateIfReachable`**（它在 `doWork`
里排在所有早退分支之前），所以「好几天不校准」只在这两种情况下成立：

1. 这一趟在走到校准之前就死了——`setForeground` 被拒（MOB-08 记录的最常见
   失败路径）、`client.bind` 失败、地址 token 解析抛；
2. 周期任务的后台档约束（Wi-Fi / 电量不低）长期不满足，任务压根没跑。

本次落地的是①：把校准提成独立单元 + 在 finally 补一次，于是**备份一步都没
开始也能校准完**。②不是应用层能修的（约束不满足就是不该跑），而「daemon 不
可达 → 保留缓存不清零」是卡明确要求的行为，不是缺陷。刻意**没有**新开一趟
周期任务——MOB-17 定调过兜底不该更频繁。

### 测试输出

```
$ cargo nextest run --all-features
Summary [10.986s] 317 tests run: 317 passed, 1 skipped
$ just ci
==> CI pipeline: all green ✅   （fmt + clippy + test + arch-check B.1/B.2）

$ cargo test -p daemon --test sync_flow
test deleted_asset_is_still_reported_missing_no_tombstone ... ok
test external_deletion_reconciles_index_thumbs_and_audit ... ok
test result: ok. 2 passed; 0 failed

$ ./gradlew :app:testDebugUnitTest --rerun-tasks      （36 个类）
BUILD SUCCESSFUL — 263 tests, 0 failures
  TEST-...CalibrationTest.xml  tests=10 failures=0

$ npx vitest run   （apps/desktop）
Test Files 3 passed (3) · Tests 24 passed (24)
$ npx vite build
✓ 208 modules transformed. ✓ built in 765ms
```

### 反证（都真跑了，不是声称）

**①手机端：去掉 `confirmed` 交集**（`lostFromLibrary` 改成 `missing.toSet()`）：

```
CalibrationTest > transfer_failed_photos_never_trigger_the_notice FAILED
  java.lang.AssertionError: 传输失败的照片不许触发提示: [half-sent, timed-out]
CalibrationTest > new_photos_never_trigger_the_notice FAILED
  java.lang.AssertionError: 新照片不许触发提示: [brand-new]
10 tests completed, 2 failed
```

**②桌面端：去掉 action 过滤**（不再只认 `asset.removed_external`）：

```
✕ add_and_move_never_warn：收录与挪位置不警告
  - Expected: null
  + Received: { "count": 4, "latestAt": 1787299999500 }
Tests 1 failed | 5 passed (6)
```

**③反墓碑判据的反证是内建的**：任何让「删掉的 hash 不再被报 missing」的改动
（含 30 天软删式隐式墓碑）都会让 `still_missing` 变空，那条 `assert_eq!` 立刻红。

### 还差什么

- **真机验收（验收人自己跑，agent 做不了）**：验收标准最后一条。要看三样——
  ①卡开头那组数字比对，改后「库里没有 = 0」；②访达里删若干张 → 桌面端总览页
  出现警告条；③手机端出现「资源在客户端丢失，正在重传」那条通知，且照片确实
  被传回来。
- 一条已知边界（卡面「一条已知边界」那节原样成立）：提示**不是拦截点**，
  校准与重传在同一趟里，中间没有让用户反应的窗口。
- 一条顺带记下的并发边界：手动通道与周期通道可以并发跑（`MOB-33` 已开卡），
  两轮都可能在对方 `removeMissing` 之前看到同一批 missing。通知用固定 id
  收敛成一条，不另做去重状态。
