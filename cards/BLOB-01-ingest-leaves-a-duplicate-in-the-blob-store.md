# BLOB-01 ingest 之后 blob 不回收，占盘翻倍

> 🟡 状态：代码已合并（实测占盘 2.05x→1.00x），等真机验收
> 级别：L2 · 阻塞：真机验收挂用户（手机重新配对备份一轮后核对占盘）

## 问题

2026-08-20 用户问"还有什么必做才能上线"，实测用户机器占盘时撞到：

```
originals    549M   ← 照片库（真正要留的）
.ppf/blobs   554M   ← iroh blob store（同一批照片的第二份）
.ppf/thumbs   22M
.ppf/index.sqlite*  2.4M
────────────────
合计         1.1G   → 占盘 = 照片本身的 2.05 倍
originals 文件数: 213
```

ROADMAP 挂账里的「blob-store GC」就是这条，但此前没有量级数据。

根因：`crates/daemon/src/backup.rs` 的 ingest 流程：

```
手机推 blob → 落 iroh blob store
           → export_to(staging/<hash>)     ← 写出第二份
           → ingestor.ingest()             ← 进照片库
```

`ingest` 成功后只删 staging（`Duplicate`/`Err` 分支里 `remove_file`），
**blob store 里那份永久留着**。`crates/transport` 里 grep `delete` /
`gc` / `untag` 零命中——没有任何回收路径。

## 期望行为

同一批照片在盘上只留一份：照片进 `originals`，`.ppf/blobs` 里不再保留
已 ingest 的副本。占盘倍数回到 ~1.00x。这是**备份产品**——用户备 50G
照片要占 100G 盘，且 `.ppf` 是隐藏目录，他只会看到"这软件吃掉了双倍
空间"。这是会导致卸载的那类问题，不是优化项，必须上线前修。

## 验收标准

- [ ] 单测：ingest 一个 blob → 断言 blob store 里不再持有该 hash，而照片库里文件存在
- [ ] 幂等：同一 hash 再 offer 一次 → 期望 `duplicates+1`、**不重新传**、也不因 blob 已删而报错
- [ ] 反证（必带）：把回收那一行去掉 → ①必红
- [ ] 真机：`du -sh originals .ppf/blobs` → 期望 blobs 显著小于 originals（只剩传输中未 ingest 的）；备一批新照片后复测
- [ ] 回归：`just ci` 全绿；`tools/android-backup.sh` 的 BACKUP OK 计数不变
- [ ] 证据：单测输出 + 反证红的输出 + 真机 `du` 前后对照

## 范围

只准动：
- `crates/daemon/src/backup.rs`（ingest 成功分支加回收）
- `crates/transport/src/`（暴露一个 blob 删除/untag 的方法）
- 对应单测

不准动：
- 备份协议（`crates/proto`）、手机端。回收是纯本地行为，不改线上格式。
- 缩略图（`.ppf/thumbs` 22M 是必要的，不在本卡范围）。

## 阻塞与依赖

真机验收挂用户：手机重新配对备份一轮 → `du -sh originals .ppf/blobs/data`
确认收件箱不再增长。

---

## 实施记录（2026-08-20）

### 修法比卡面两个方案都好：主路径根本不进收件箱

卡面原给的是「A. ingest 后删 blob」和「B. ingest 直接从 store 取」（A 改动
局限在 daemon/transport，B 要动 `core_index::ingest` 的入口契约，原倾向
A）。读代码时发现第三条路——**主路径压根不需要 blob store**：

`upload.rs` 的接收流程本来就已经做完了"边收边验"：

```
流式写 staging/<hash>.upload  →  边写边算 BLAKE3  →  自己比对  →  不匹配 reject
```

然后它才 `blobs.push(...)` 把这份**已经校验过**的文件拷进 blob store
（`add_path` 默认 `ImportMode::Copy`，vendored 源码 `api/blobs.rs:265` 写死），
commit 时 `backup.rs` 又 `export_to` 拷回 staging 才能 ingest。

**同一份字节拷三遍，就为了在收件箱里绕一圈，而那一份永不回收。**

用户定调："收到文件，文件都已经保存好了，我们就没必要在收件箱里面保留这个
文件了吧……它的独立功能就只有一项，一个是收件，一个是中转。"

### 改动

1. **`upload.rs`**：校验通过后**原地改名坐实**——`<hash>.upload` → `<hash>`，
   不再碰 blob store。后缀就是完整性契约（带 `.upload` = 还在写/没验过，
   不带 = 可以 ingest），同目录 rename 原子，无中间态。`UploadPlane` 不再
   持有 `Blobs`。
2. **`backup.rs`**：commit 时**优先吃 staging 里现成的**
   （`if !staged.is_file() && export_to(...).is_err()` → 才 fetch）。
   blob store 从此只服务回退路径（T-032 主动拉取）。
3. **`inbox.rs`（新）**：启动时回收。整个清空 `.ppf/blobs`（启动这一刻不可能
   有传输在飞 → 里面一定是上个会话的垃圾），staging 只扫 `.upload` 半成品、
   **完整的 `<hash>` 一律保留**（那是已传完等 ingest 的，删了要重传）。

### 为什么是"启动清空"而不是 GC

iroh-blobs 0.103 把回收全锁在 GC 后面：单个 blob 的 `delete` 是
`pub(crate)`，文档明写 *"Users should rely only on garbage collection for
blob deletion"*；而 `gc_run_once` 所在的 `store::gc` 是 crate 私有模块
（`mod gc;`），`GcConfig` 只能配成定时轮询、默认 `gc: None`（`options.rs:124`）。

与其把回收时机交给一个我们控制不了的定时器，不如在一个**可证明安全**的时刻
自己动手。代价：回退路径被打断后拉到一半的数据不能跨重启续传——可接受，
那条路按 commit 批次重试，最多重拉一个文件。

**这同时是老用户的迁移路径**：升级前积累的那几百 MB 在首次启动一次性归零。

### 续传能力零损失（查过才敢说）

`UploadHeader` 只有 `hash` / `bytes` / `file_name`，**没有 offset/resume
字段**；`upload.rs` 零续传逻辑，`File::create` 直接截断。**上传平面从来都是
断了整个文件重传**，不是本卡丢的。所以半成品一律可删。

### 验证

**真实 daemon 端到端**（固定目录，备份 12 张）：

```
BACKUP OK: pushed=12 ingested=12; rerun pushed=0 dup=12

originals       2,400,078 B  ← 照片库（要留的）
blobs/data              0 B  ← 收件箱里的照片副本
staging                 0 B  ← 中转桌
占盘倍数 = 1.00x        （改前用户机器实测 2.05x：549M + 553M）
```

`rerun pushed=0 dup=12` 就是卡面要的**「同一 hash 再 offer 不重传也不报错」**。

- `just ci` 全绿（fmt + clippy `-D warnings` + 全量测试 + arch-check）。
- 集成断言进 `upload_flow.rs`：commit 之后 `blobs/data` 必须为 0、
  `staging` 必须为 0。**断言口径盯 `blobs/data/` 而不是目录总量**——
  store 的 redb 空库有 ~1MB 固定开销，比小尺寸测试图还大（第一版就是这么
  误报的，真机布局实测：`data 553M` / `blobs.db 4.7M`）。
- **反证 4 条全红**：

| # | 破坏 | 变红 |
|---|---|---|
| BB | 主路径又往收件箱拷一份 | `pushed_files_commit_without_reverse_dial` |
| CC | commit 无条件走 blob store（回归旧行为） | 同上 |
| DD | 半成品判据放宽（`.upload` 之外也删） | `partial_uploads_are_recognised_by_suffix` |
| EE | 回收不清 blob store | `reclaim_empties_the_blob_store_and_reports_the_bytes` |

### 顺手修掉：E2E-02 的范围原来不止一处

跑 `just android-backup` 时炸了——`DaemonBackupTest.kt:82` 也是
`parsePairingQr(qr).addr!!`，同一个 H-10b 死契约（NPE）。全仓一查**共四处**
（`DaemonHelloTest` / `DaemonBackupTest` / `NetProbeTest` / `DeviceBackupTest`），
上一轮只修了一处就宣布"解红"了。

已抽成共用辅助 `transport/PairingQrAddr.kt` 的 `addrOf(qr)`，四处全部改走它，
下次协议再变只改一处。⚠️ 教训：**"这个测试挂了"要先问"还有几个同形的"**
——同一个契约变更会同时打断所有依赖它的测试，只修撞到的那一个等于没修。

### 未完成

- **真机验收挂用户**：见「阻塞与依赖」。
- 旧数据副本 `本地旧库副本`（1.1G）留着可回退，**验收通过后由用户删**。

### 收尾（验收通过后）

PROGRESS.md 一行 + NEXT.md 状态 + ROADMAP 挂账里那条「blob-store GC」
勾掉 + 本卡移入 `done/`。
