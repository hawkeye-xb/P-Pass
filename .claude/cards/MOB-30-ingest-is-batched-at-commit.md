# MOB-30 收到的照片攒到最后才入库，中断要整批重传　级别 L2

> 🟡 状态：代码已合并，等真机验收。用户裁决改法①（逐张入库）。
> 用户 2026-08-21 观察：「我在备份所有照片的时候，它是一次性地
> 出现。也就是说，我们收到货后，是不是还批量地去改名，而不是收到货就会执行
> 改名的操作？」——**猜对了。**

## 现在的流程（代码核过）

手机侧 `BackupRunner.run`（`BackupRunner.kt:72/81/103/112`）：

```
backup.begin → backup.manifest → 循环 pushFile(每张) → backup.commit（一次）
```

daemon 侧：

- **上传是逐张的**：每张流式校验 BLAKE3，通过后 `<hash>.upload` 原地改名成
  `<hash>`，落在 `staging/`（BLOB-01）
- **入库是批量的**：`place()`（搬进 `originals/`）+ 插索引行，**全部发生在
  `backup.commit` 里**，也就是**所有文件都传完之后**（`backup.rs:144` 的
  `commit` 循环）
- 事件节流窗口 1 秒（`events.rs:44`），12 张在 1 秒内 ingest 完 → 只发**一次**
  `timeline.invalidated`

## 两个后果

### ① 进度不可见（用户看到的）

传 500 张时，照片墙 8 分钟毫无动静，最后一秒全部冒出来。用户无法判断「在传」
还是「卡死了」。

### ② 中断要整批重传（更贵，用户还没撞到）

`manifest` 计算 `missing` 只查索引（`backup.rs:113/125` 的 `db.get_asset`），
**不看 staging**。所以传到第 400 张断掉时：

- 400 个文件安然躺在 `staging/`
- 但索引一条都没有 → 下一轮 manifest 报「400 张全 missing」
- 手机把这 400 张**重新上传一遍**

BLOB-01 记的「续传零损失：`UploadHeader` 无 offset 字段，断了整个重传」是
**单文件**级别；commit 的批量性把它放大成**整批**级别。

## 用户裁决

> 「上传是主动的，我觉得入库也应该是主动的，而不是说批量。」

→ **改法①逐张入库**。

## 已实施

- 抽出 `BackupEngine::ingest_one`——单条入库的**唯一**实现，上传路径与
  commit 路径共用。各写一遍必然漂移（MOB-19 手动/自动两条备份管线就是这么
  烂掉的）。
- 新增 `BackupEngine::ingest_staged(peer, hash)`：上传平面收完一张、校验通过
  改名成 `staging/<hash>` 之后**立刻**调它。失败**不让那条流失败**（文件已
  校验落盘，commit 会兜底；把 ACK 变成错误只会让手机重传这一张），但留 warn
  日志，不静默吞。
- `Session` 加 `ingested` / `duplicates` / `settled` 三项记账：
  - 前两项让 `commit` 报的数字**把上传阶段入库的算进去**——否则 commit 只会
    看到「它们已在索引里」并当成 duplicates，界面报「新增 0 张」
  - `settled` 让 `commit` **跳过且不计数**上传阶段已办的——否则它们既进了
    `ingested` 的账，又会在 commit 循环里被「已在索引里」那一支数第二遍
- `UploadPlane::new` 多收一个 `BackupEngine`（`main.rs` 与两个集成测试的装配
  同步改了）。

**后果②顺带解掉了**：断点之前的都已进索引 → 下一轮 `manifest` 算出的
`missing` 不含它们 → 手机不再重传。

## 验收证据

反证 4/4 有效：

```
✅ P1  上传后不立即入库（回到攒 commit）   → index_grows_with_each_upload… FAILED
✅ P1b 同一处 → 断线后已落地的会被重传     → a_session_cut_short_does_not_re_upload… FAILED
✅ P2  commit 不跳过上传阶段已办的          → index_grows_with_each_upload… FAILED
✅ P3  commit 账从 0 起（不算上传入库的）   → index_grows_with_each_upload… FAILED
```

新增集成测试（走真 transport + 真上传平面）：

- `index_grows_with_each_upload_not_only_at_commit` —— 逐张上传，**每张之后
  索引都必须已经多一行**；commit 仍如实报 `ingested=3 / duplicates=0`
- `a_session_cut_short_does_not_re_upload_what_already_landed` —— 传 2/3 张
  后不 commit，新会话的 `missing` 必须只剩没传的那一张

`just ci` 全绿，Rust **307/307**。BLOB-01 的两条已验证性质与
`interrupted_commit_rerun_converges` 都仍然绿。

## 原先列的三个改法（留档）

1. **逐张 commit**：每张传完就 ingest。进度自然可见，中断只丢当前这张。
   代价：索引写入从一次批量变成 N 次，且要想清楚 `backup.finished` 审计与
   水位推进的时机。
2. **manifest 认 staging**：`missing` 计算时先看 `staging/<hash>` 在不在。
   最小改动，只解决后果②，不解决①。
3. 只改事件节流：只解决①的观感，不解决实质（照片确实还没入库）。

⚠️ 注意别破坏 BLOB-01 的两条已验证性质：同一 hash 重复提交不重传也不报错；
传输中触发回收不影响正在传的那批。以及 `interrupted_commit_rerun_converges`
这条既有集成测试的语义。

## 验收要求

- 集成：传 N 张的过程中，索引行数必须**单调递增**而不是最后一跳（钉住①）
- 集成：传到一半杀掉连接 → 重跑时**已 staging 的那些不再重新上传**（钉住②）
- 反证两条都要有
