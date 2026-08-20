# BLOB-01 ingest 之后 blob 不回收，占盘翻倍　级别 L2

**发现于**：2026-08-20 用户问"还有什么必做才能上线"，实测用户机器占盘时撞到。
ROADMAP 挂账里的「blob-store GC」就是这条，但此前没有量级数据。

## 现场证据（用户真机 macOS，`/Users/zhaowenli/P-Pass NAS`）

```
originals    549M   ← 照片库（真正要留的）
.ppf/blobs   554M   ← iroh blob store（同一批照片的第二份）
.ppf/thumbs   22M
.ppf/index.sqlite*  2.4M
────────────────
合计         1.1G   → 占盘 = 照片本身的 2.05 倍
originals 文件数: 213
```

## 根因

`crates/daemon/src/backup.rs` 的 ingest 流程：

```
手机推 blob → 落 iroh blob store
           → export_to(staging/<hash>)     ← 写出第二份
           → ingestor.ingest()             ← 进照片库
```

`ingest` 成功后只删 staging（`Duplicate`/`Err` 分支里 `remove_file`），
**blob store 里那份永久留着**。`crates/transport` 里 grep `delete` /
`gc` / `untag` 零命中——没有任何回收路径。

## 为什么必须上线前修

这是**备份产品**。用户备 50G 照片要占 100G 盘，而且他不会理解为什么——
`.ppf` 是隐藏目录，他看到的只是"这软件吃掉了双倍空间"。这是会导致卸载的
那类问题，不是优化项。

## 两条修法（实施时二选一，写进卡）

**A. ingest 成功后删 blob。** 改动小，但要确认：iroh blobs 的删除语义
（tag / GC）在我们这版是什么、删掉之后手机端重复 offer 同一 hash 会不会
因为"store 里没有"而重新传（应该不会——去重是 daemon 查 `get_asset`
数据库，不查 blob store，但必须有测试锁住）。

**B. ingest 直接从 blob store 取，不落 staging 第二份。** 更彻底，但要动
`core_index::ingest` 的入口契约（现在吃 `src_path`）。

倾向 A：改动局限在 daemon/transport，B 会牵动 ingest 契约。

## 范围

只准动：
- `crates/daemon/src/backup.rs`（ingest 成功分支加回收）
- `crates/transport/src/`（暴露一个 blob 删除/untag 的方法）
- 对应单测

## 不准动

- 备份协议（`crates/proto`）、手机端。回收是纯本地行为，不改线上格式。
- 缩略图（`.ppf/thumbs` 22M 是必要的，不在本卡范围）。

## 可执行验收

1. **单测**：ingest 一个 blob → 断言 blob store 里不再持有该 hash，
   而照片库里文件存在。
2. **幂等**：同一 hash 再 offer 一次 → 期望 `duplicates+1`、**不重新传**、
   也不因为 blob 已删而报错。这是 A 方案最容易踩的坑。
3. **反证**（必带）：把回收那一行去掉 → ①必红。
4. **真机**：`du -sh originals .ppf/blobs` → 期望 blobs 显著小于 originals
   （只剩传输中未 ingest 的）。备一批新照片后复测。
5. **回归**：`just ci` 全绿；`tools/android-backup.sh` 的 BACKUP OK 计数不变。

## 证据要求

单测输出 + 反证红的输出 + 真机 `du` 前后对照。

## 收尾

`just ci` 绿 + PROGRESS.md 一行 + NEXT.md 状态 + ROADMAP 挂账里那条
「blob-store GC」勾掉 + 本卡移入 `done/`。
