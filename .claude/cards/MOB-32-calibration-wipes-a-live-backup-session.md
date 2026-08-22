# MOB-32 校准把正在跑的备份 session 清空，186 张照片传上来后被静默丢弃　级别 **L0**

> 🟡 状态：代码已合并，等真机验收
> 级别：L0 · 阻塞：无
>
> **这是整个项目目前最严重的缺陷**：用户的照片传到了存储端、通过了校验、
> 然后被扔掉，而手机报告「已备份」。

## 问题

实测证据（2026-08-21 用户真机，清场前当场取的）：

```
.ppf/staging     547M   ← 186 个已校验文件
其中 .upload         0   ← 全部通过了 BLAKE3 校验
已进索引             1
纯孤儿             185   ← 传上来了，从没入库，永远不会被回收
originals          3.4M  ← 库里只有 5 个文件
.ppf/blobs/data      0B  ← BLOB-01 仍然成立，泄漏点换成了 staging
```

文件时间戳：11:18 ×13、11:19 ×49、11:20 ×65、11:21 ×54、11:22 ×5。

存储端审计对应段：

```
11:20:52  backup.started
11:22:05  backup.finished   ingested=0 duplicates=0   ← 186 张全丢
```

手机侧同时：`confirmed.json` 有 **188** 条，`bucketOf` 里 **186 条属于相机相册
`-1739773001`**（不是用户选中的那个 12 张的相册）。

### 根因（代码核实，链条完整）

`backup.begin` 的实现是**无条件重置** session：

```rust
pub fn begin(&self, peer: transport::NodeId) {
    self.sessions.lock().expect("sessions lock")
        .insert(peer, Session::default());     // ← 直接盖掉
}
```

而**漂移校准也走这条路**：`BackupRunner.existCheck`（`BackupRunner.kt:139`）
= `backup.begin` + `backup.manifest(items = emptyList())`。

session 是**按设备 NodeId** 索引的，校准和备份是同一把钥匙。于是：

```
手机备份中： begin → manifest(186 items) → 逐张上传 186 张进 staging
用户打开 App：BackupUiStateHolder.init 的 calibrateFromDaemon() → begin
             ★ session.items 被清空
手机 commit： items 为空 → 循环零次 → ingested=0 duplicates=0，但**返回 ok**
手机收到 ok → recordRun 把这一批全部标记「已备份」
staging：   186 个已校验文件成为孤儿，547MB
```

三个独立的错：

1. **`begin` 不该清掉正在进行的会话。** 校准只需要「问一下你有没有这些
   hash」，它根本不需要一个会话。而 `begin` 的契约注释写着 "Idempotent"
   ——它对**空闲**设备是幂等的，对**正在上传**的设备是毁灭性的。
2. **`commit` 报 `ingested=0` 却返回成功，手机据此宣布「已备份」。** 手机
   的判据是「调用没抛异常」。一次上传了 186 个文件、commit 却说入库 0 张，
   这是一个**必须让手机知道的矛盾**，不能算成功。
3. **staging 没有回收路径（占盘泄漏）。** `inbox.rs` 的 `is_partial_upload`
   只认 `.upload` 后缀：
   ```rust
   path.extension().and_then(|e| e.to_str()) == Some("upload")
   ```
   **已校验完成**（无后缀）但没被 ingest 的文件，回收逻辑永远碰不到。
   BLOB-01 把 `blobs/data` 压到了 0，泄漏点搬到了 staging：本次 547MB。

## 期望行为

- 校准不破坏正在进行的备份会话；旧版 APK 打新 daemon 也不能坏（修复必须
  落在 daemon 侧）。
- commit 在「本会话上传过 N 个文件但入库 0 张」时**不得**返回成功，水位
  不推。
- staging 里已校验但未被任何索引行引用的文件必须能被回收，且不得误删正在
  上传的（`.upload`）与刚落地待 ingest 的。

## 验收标准

- [x] 集成：一次上传进行中，另一条连接调 `backup.begin` → 原会话的 items
  **不得**丢失；commit 仍然如实入库并报数
  （`a_calibration_mid_upload_does_not_lose_the_session`，2026-08-21）
- [x] 集成：commit 在「本会话上传过 N 个文件但入库 0 张」时**不得**返回
  成功（`commit_refuses_to_report_success_when_a_delivered_file_never_landed`）
- [x] 集成：staging 里存在已校验但未被任何索引行引用的文件 → 启动/定期
  回收必须清掉它们，且**不得**误删正在上传的（`.upload`）与刚落地待 ingest
  的（`staging_orphans_are_reclaimed_but_claimed_files_are_not` 等）
- [x] 反证：每条都要有（2026-08-21 反证 9/9 有效，明细见验收证据）
- [x] `just ci` 全绿，Rust 313/313，Android 253/253（2026-08-21）
- [ ] 真机：跑一次完整备份，**中途打开 App**（触发校准）→ 照片数必须全部
  到位，staging 收尾为 0 字节（欠用户；两条剧本实话见文末「真机验收」）

## 范围

- 只准动：daemon 侧 `backup.rs`（begin/commit）、`inbox.rs`（孤儿回收）、
  `main.rs`（启动回收、janitor）、上传平面交付台账；手机侧
  `BackupRunner.existCheck`（删掉校准里的 `backup.BEGIN`）及对应测试。
- 不准动：`PairFlow.kt:76` 拿 `backup.begin` 当成员权限探针那条（daemon 侧
  已非破坏化，它现在无害）。

## 阻塞与依赖

真机验收欠用户。无其它前置。

---

## 实施记录

### MOB-30 已经堵住了主漏（但不能替代本卡）

MOB-30（逐张入库，2026-08-21 已合并）让文件在**上传完成的那一刻**就进索引，
不再等 commit。所以「session 被清空 → 已上传的全丢」这条主路径**已经断了**。

但本卡仍然必须做：

- `begin` 清活跃 session 依然会**弄坏 commit 报的数字和水位推进**
- 即时入库失败的兜底路径仍然依赖 commit 的 items（MOB-30 里那句
  `tracing::warn!("留给 commit 兜底")`）——session 被清空就没兜底了
- 存量库里的 staging 孤儿仍然没人回收

### 我在这件事上的错误（记下来）

上一轮我对用户说「**不是在执行全量同步，是显示问题**」。前半句是错的。

我当时的证据是真的（`WorkProgress` 零行、我检查那一刻没有 work 在跑、
`ppass-auto-backup` 排队未跑），但我**把「此刻没在跑」外推成了「那次没发生过」**。
真相是：全量上传确实发生了（11:18–11:22，547MB），只是 commit 把它扔了，所以
存储端审计里看不到 ingest，我就误判了。

⚠️ **教训：审计里"没有 X 发生"不等于"X 没被尝试过"。** 判断"传了没有"要去看
**中转区/磁盘**，不能只看入库审计——被丢弃的工作恰恰不会留下入库记录。
清场前顺手 `du -sh` 那一下才是抓到它的原因。

### 改动（2026-08-21）

#### ① `begin` 不再破坏活会话

`backup.rs`：`insert(peer, Session::default())` → `entry(peer).or_default().touch()`。

会话的生命周期从此归两处，**都不是 `begin`**：

- `commit` 成功收尾时 `remove`
- janitor `sweep_sessions(SESSION_IDLE_TTL)` 收掉空闲超过一小时的

`Session` 加 `touched_at: Instant`，begin / manifest / 逐张入库都续命。
TTL 取一小时的下界理由：一轮备份里会话被 touch 的**最大间隔就是一个文件**，
一段 4K 视频走慢速局域网是分钟级。

手机端 `BackupRunner.existCheck` 里那次 `backup.BEGIN` 也删了——校准根本不
需要会话（`manifest` 自己 `entry().or_default()`）。但**daemon 侧的修复必须
独立成立**：旧版 APK 打新 daemon 也不能坏。

⚠️ **`begin` 被当 ping 用的地方不止一处。** 收尾时 grep 出第三个调用点：
`PairFlow.kt:76` 拿 `backup.begin` 当**成员权限探针**（注释原文：
"backup.begin is member-gated: an ok means we're recognised"）。也就是说旧
代码下「备份途中扫一次配对码」同样会清空会话。这条不动（daemon 侧已经非
破坏化，它现在无害），但它正是**修必须落在 daemon 侧、不能只改手机**的证据：
一个 RPC 一旦被当成「便宜的探针」，它有几个调用方就是不可知的。

#### ①附带：commit 的拉取回退加 `provider` 门（审出来的回归）

`begin` 不再清空会话之后，**新出现一条风险**：上一轮声明过、但手机上已经被
删掉的照片会作为「幽灵 item」留在 items 里。commit 对它走 `fetch_from`，而
手机从不 serve blobs（`provider = null` 就是这个契约）→ `BackupError::Fetch`
→ **报错时 `sessions.remove` 走不到**（`?` 提前返回）→ 会话不死、重试又把它
touch 活 → janitor 也收不走 → 备份一直红。

这条今天不可达，**正因为 `begin` 会清空**。把清空拿掉它就可达了。

修法：`provider.is_none()` 的推送型会话遇到「不在索引、不在 staging、blob
store 也没有」的 item → 跳过 + warn，不报错不计数。手机上已经没有这张照片
了，本来就没有东西可备份。

#### ② commit 报 0 入库时不许返回成功

新增 `delivered` 台账：`Arc<Mutex<HashMap<NodeId, u32>>>`，上传平面校验通过
就 `note_delivered(peer)`。

**故意不放在 `Session` 里**——session 可能被顶掉（那正是本卡的事故），而
「这台设备本轮确实交付了 N 个文件」这条证据必须活得比 session 长，否则
commit 无从发现矛盾。

```rust
if delivered > 0 && outcome.ingested == 0 && outcome.duplicates == 0 {
    return Err(BackupError::NothingIngested { delivered });
}
```

水位也不推（推了下一轮连候选都不会再产生）。台账只在**成功收尾**时清。

#### ③ staging 孤儿回收

`inbox::sweep_orphans(staging, protected, grace)`。孤儿判据 = 裸文件 ∧ 不在
保护集 ∧ 落地超过 `grace`。三道保护缺一个都会误删用户的照片。

- 启动（`main.rs`）：保护集恒为空——会话是内存态，重启后没有裸文件还有主
- 每小时（挂进已有的 SYNC-01 循环）：`BackupEngine::reclaim_staging` 带上
  所有活会话声明过的 hash

**这是一次有记录的裁决反转。** BLOB-01 当时写的是「裸文件一律保留」，理由
是「下一轮备份手机会重新 offer 同一个 hash，省一次上传」。这条推理有个没被
验证的前提：**手机一定会再 offer 一次**。本卡的事故恰恰打掉了它——commit 报
了个假的 `ok`，手机把 186 张全标记「已备份」，从此再也不 offer。547MB 成了
永久孤儿。现在的权衡是**正确性优先于带宽**：崩溃重启后可能多传一次，认了。

### 验收证据

反证 9/9 有效（每处修复改回去，对应测试必须变红）：

```
✅ M1 begin 改回无条件重置          → a_calibration_mid_upload_does_not_lose_the_session FAILED
✅ M2 删掉「交付 N 入库 0」检查      → commit_refuses_to_report_success_when_a_delivered_file_never_landed FAILED
✅ M3 删掉 provider 门              → a_push_session_skips_an_item_the_phone_never_delivered FAILED
✅ M4 孤儿判据不看活会话保护集       → staging_orphans_are_reclaimed_but_claimed_files_are_not FAILED
✅ M5 孤儿判据不看落地宽限期         → inbox::tests::orphan_sweep_respects_every_guard FAILED
✅ M6 上传平面不记交付台账           → commit_refuses_to_report_success…_never_landed FAILED
✅ M7 janitor 判据取反               → staging_orphans_are_reclaimed_but_claimed_files_are_not FAILED
✅ M8 启动回收不扫孤儿               → inbox::tests::reclaim_sweeps_orphans_past_the_grace_window FAILED
✅ M9 existCheck 把 begin 加回去     → calibration_never_opens_a_backup_session FAILED（Kotlin）
```

新增测试：

- `a_calibration_mid_upload_does_not_lose_the_session` —— 真机那次事故的形状：
  传一张 → 校准（begin + manifest(items 空)）→ 传剩下两张 → commit 必须报
  `ingested=3`，且 **staging 收尾为 0 字节**（留下的每个字节都是丢掉的照片）
- `commit_refuses_to_report_success_when_a_delivered_file_never_landed` ——
  用**探测型 manifest**（items 空）从公开 API 构造出「交付了但无从入库」的
  会话，不需要任何测试后门
- `a_push_session_skips_an_item_the_phone_never_delivered` —— 幽灵 item
- `staging_orphans_are_reclaimed_but_claimed_files_are_not` —— 三道保护 +
  「janitor 收走会话后，它保护的孤儿就该被回收」
- `inbox` 单测：`orphan_sweep_respects_every_guard`、
  `reclaim_sweeps_orphans_past_the_grace_window`
- Kotlin：`calibration_never_opens_a_backup_session`（夹出 `existCheck`
  函数体断言，不是全文 contains——全文一定命中 `run()` 里那个正当的 begin）

`just ci` 全绿，Rust **313/313**，Android **253/253**。

### ⚠️ 反证驱动第四次被同一个形状咬

M5/M8 第一轮报「仍然绿 = 恒真式」。真相是
`cargo test -p daemon --lib <短名> -- --exact` **一个测试都没匹配到**
——`--exact` 对 lib 测试要写全模块路径（`inbox::tests::x`）。cargo 退 0，
被我当成了「绿」。

前三次分别是：`str.replace` 锚点不存在导致变异静默 no-op、`grep '^e:'`
没匹配到 gradle 的 `Unable to locate a Java Runtime`、`sliceAfter` 把整个
文件带进断言。**同一个根源：某种"没找到"被当成了"通过"。**

驱动现在解析 `running (\d+) tests`，跑到 0 个测试直接判反证无效。

### 已知不追（记一笔）

daemon 重启会丢 `delivered` 台账 → 重启前交付、重启后 commit 会报 0/0 成功。
不追：MOB-30 已让每张照片在**上传当刻**入库，重启前交付的都在索引里，手机
标记「已备份」是真的，只是数字为 0。

### 真机验收（欠用户）

- 跑一次完整备份，**中途打开 App**（触发校准）→ 照片数必须全部到位
- 收尾后 `du -sh "<库>/.ppf/staging"` 必须是 0

⚠️ **两条剧本上的实话，别拿它们当失败信号：**

1. **不会看到「回收 staging 孤儿」那行日志。** 库已被 `reset-local.sh` 整体
   删掉，白板环境没有存量孤儿。想看现场就人工造一个：daemon 启动前往
   `.ppf/staging` 放个裸文件、`touch -t` 把 mtime 拨到一小时前。存量回收本身
   由 `reclaim_sweeps_orphans_past_the_grace_window` 钉死。
2. **真机踩不到 `begin` 保活那条路了。** 新 APK 的校准不再发 `begin`，所以
   「备份途中打开 App」在真机上只会打一次 manifest-only 的校准。旧 APK 的
   形状由 `a_calibration_mid_upload_does_not_lose_the_session` 钉死（那个测试
   **特意照旧发 begin**）。⚠️ 不要为了让真机踩到就把 `begin` 加回去。
