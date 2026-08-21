# MOB-32 校准把正在跑的备份 session 清空，186 张照片传上来后被静默丢弃　级别 **L0**

> ⛔ 未实施。**这是整个项目目前最严重的缺陷**：用户的照片传到了存储端、
> 通过了校验、然后被扔掉，而手机报告「已备份」。

## 实测证据（2026-08-21 用户真机，清场前当场取的）

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

## 根因（代码核实，链条完整）

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

两个独立的错都要修：

### ① `begin` 不该清掉正在进行的会话

校准只需要「问一下你有没有这些 hash」，它根本不需要一个会话。而 `begin` 的
契约注释写着 "Idempotent" —— 它对**空闲**设备是幂等的，对**正在上传**的设备
是毁灭性的。

### ② `commit` 报 `ingested=0` 却返回成功，手机据此宣布「已备份」

手机的判据是「调用没抛异常」。一次上传了 186 个文件、commit 却说入库 0 张，
这是一个**必须让手机知道的矛盾**，不能算成功。

### ③ staging 没有回收路径（占盘泄漏）

`inbox.rs` 的 `is_partial_upload` 只认 `.upload` 后缀：

```rust
path.extension().and_then(|e| e.to_str()) == Some("upload")
```

**已校验完成**（无后缀）但没被 ingest 的文件，回收逻辑永远碰不到。BLOB-01 把
`blobs/data` 压到了 0，泄漏点搬到了 staging：本次 547MB。

## MOB-30 已经堵住了主漏（但不能替代本卡）

MOB-30（逐张入库，2026-08-21 已合并）让文件在**上传完成的那一刻**就进索引，
不再等 commit。所以「session 被清空 → 已上传的全丢」这条主路径**已经断了**。

但本卡仍然必须做：

- `begin` 清活跃 session 依然会**弄坏 commit 报的数字和水位推进**
- 即时入库失败的兜底路径仍然依赖 commit 的 items（MOB-30 里那句
  `tracing::warn!("留给 commit 兜底")`）——session 被清空就没兜底了
- 存量库里的 staging 孤儿仍然没人回收

## 我在这件事上的错误（记下来）

上一轮我对用户说「**不是在执行全量同步，是显示问题**」。前半句是错的。

我当时的证据是真的（`WorkProgress` 零行、我检查那一刻没有 work 在跑、
`ppass-auto-backup` 排队未跑），但我**把「此刻没在跑」外推成了「那次没发生过」**。
真相是：全量上传确实发生了（11:18–11:22，547MB），只是 commit 把它扔了，所以
存储端审计里看不到 ingest，我就误判了。

⚠️ **教训：审计里"没有 X 发生"不等于"X 没被尝试过"。** 判断"传了没有"要去看
**中转区/磁盘**，不能只看入库审计——被丢弃的工作恰恰不会留下入库记录。
清场前顺手 `du -sh` 那一下才是抓到它的原因。

## 验收要求

- 集成：一次上传进行中，另一条连接调 `backup.begin` → 原会话的 items **不得**
  丢失；commit 仍然如实入库并报数
- 集成：commit 在「本会话上传过 N 个文件但入库 0 张」时**不得**返回成功
- 集成：staging 里存在已校验但未被任何索引行引用的文件 → 启动/定期回收必须
  清掉它们，且**不得**误删正在上传的（`.upload`）与刚落地待 ingest 的
- 反证：每条都要有
- 真机：跑一次完整备份，中途打开 App（触发校准）→ 照片数必须全部到位，
  staging 收尾为 0 字节
