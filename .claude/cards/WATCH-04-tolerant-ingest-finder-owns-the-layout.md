# WATCH-04 宽容入库：`originals/` 是用户的目录　级别 L1

> 🟡 状态：代码已合并，等真机验收。
> 已做：宽容落位 + 路径唯一性 + 重建归属口径对齐 + 测试与反证。
> 还差：真机在 Finder 里建目录/挪照片/编辑照片三个动作的观感确认。

## 用户裁决（2026-08-21）

> 「我人工往底层目录移动的这种超高权限的操作呢？应该忽略不符合格式的？
> 还是我们去像 OS 一样兼容？」→ 兼容。
> 「非预期的照片，用本机标签分类？也按照时间挂入？」→ 是。
> 「其它非目标文件肯定要过滤的。」→ 保持白名单不变。

## 规则（一句话）

**`originals/` 底下任何位置的媒体文件都照原样入索引；`mv` 到 canonical
日期布局只对「我们自己从手机收到的文件」执行 —— 那些文件此刻还在 staging，
本来就得给它找个家。**

## 三条支撑理由

1. **宽容不额外花钱。** 实测（`docs/product/2026-08-21-macos-fs-events.md`）：
   macOS 分不清「拖进来」和「拖出去」—— 两者都只有一条 `Modify(Name)` 落在
   树内那一侧的路径上。我们本来就必须 `stat` 每个路径才能判断。宽容不多做
   任何事，严格反而要多做一次搬移。
2. **重建路径本来就是宽容的。** `rebuild.rs` 模块注释（ADR-006）原文写着手放
   的文件照样入索引。严格入库 + 宽容重建 = **重建一次，库的语义就变了**。
3. **备份工具最不该干的事，是把用户的文件从他放的位置挪走。** 用户建了
   「我的婚礼」，第二天发现照片全跑回 `2026/08/` —— 比丢照片更让人不敢用。

## 归属：手放的文件归本机，不留空

规则：**不在任何 `<64位hex>/` 目录下的文件 = 本机。**

- 它没走过我们的上传协议，出现在库里只能是有人用本机文件系统权限放进去的
- **这条规则目录树自己就能重现**（重建总在本机跑，本机身份现成）→ ADR-006
  「光靠目录树就能完整重建索引」这条铁律**不用破**
- 留空更保守，但会让「只看我的 / 只看家人的」筛选器算不出归属、把照片
  **藏起来** —— 对家庭相册是更坏的结果

⚠️ 记账的漂移：把整个库搬到**新机器**上重建，这些文件会被归到新机器名下。
内容与时间线不受影响，只影响「谁的照片」这一栏。

`rebuild()` 签名因此从 `(db, library_root)` 变成
`(db, library_root, local_node_id)`。**注意：daemon 里目前没有任何地方调用
rebuild**，它只是个 T-012 契约，靠测试覆盖 —— 要真用上得先把它接进 daemon。

## 前置条件：一个路径只能被一条索引行占用

这条**不是可选项，不做宽容落位就是引 bug**。

`asset` 表 `hash` 是主键、`rel_path` **没有唯一约束**。用户在 Finder 里
编辑一张我们收到的照片：

1. 内容变了 → hash 变了 → 在我们眼里是**另一张照片** → 插新行
2. 老行还指着同一个路径（**文件存在，对账不会清它**）
3. → 同一个文件被两条行占着 → 照片墙上出现两次，其中一张的缩略图和原图都
   取不出来（thumb 按 hash 存）

有意思的是**旧的严格布局意外躲过了这个坑**：编辑后的文件会被 `mv` 走并加
`-1` 后缀，老路径空了，对账就清了老行。严格布局在这里是个歪打正着的补丁。

改法：入库时发现目标路径已被别的 hash 占着 → 删老行 + 审计
`asset.replaced_in_place`。

## 展示不受影响（核过）

- 时间线索引是 `(taken_at DESC, hash)`，桌面端分档「今天/昨天/本周/本月/更早」
  全部只看 `taken_at`
- 手机端的 `AssetMeta`（`crates/proto/src/msgs.rs`）只有
  `hash / taken_at / media_type / 宽高 / 字节` —— **连路径字段都没有**

**目录叫什么，对展示零影响。** 反过来说才是问题：用户建的目录在界面上完全
看不见 —— 见 `WATCH-06 相册 = 目录`。

## 验收证据

反证 5/5 有效：

```
✅ N1  宽容落位改回无条件搬走       → a_file_already_inside_originals_is_adopted FAILED
✅ N1b 同一处 → 用户放的文件被搬走  → new_media_file_is_ingested_within_seconds FAILED
✅ N2  路径唯一性：老行不让位       → editing_an_indexed_file_leaves_exactly_one_row FAILED
✅ N3  重建归属回退改回留空         → hand_dropped_files_are_picked_up FAILED
✅ N3b 同一处 → device_of 单测      → device_of_falls_back_to_local... FAILED
```

新增测试：

- `a_file_already_inside_originals_is_adopted_where_it_lies`
- `a_file_from_outside_still_lands_in_the_canonical_layout`（**反向守卫**：
  否则宽容会把「谁都不搬」当默认，上传的文件永远烂在 staging）
- `editing_an_indexed_file_leaves_exactly_one_row_at_that_path`
- `device_of_falls_back_to_local_outside_the_canonical_layout`

`watch_flow.rs` 里 6 个测试的前提（文件会被搬到日期目录）随语义变更重写为
用户自建的 `originals/2026/08/` 树 —— 测试不该假设我们的 canonical 形状。

`just ci` 全绿，Rust **305/305**。

## 已知欠账（如实记，不假装没有）

1. **孤儿缩略图**：老行让位后它的 thumb 文件没人删（thumb 按 hash 存，
   `.ppf/thumbs` 布局是 daemon 侧 `Reconcile` 的职责，core-index 不掌握）。
   与 `reconcile.rs` 里已接受的孤儿 blob 同一类：内容寻址、无任何产品路径
   引用它，惰性无害。
2. **`we_moved_it` 回滚分支无测试覆盖**：insert 失败时只回滚我们自己搬进来的
   文件（就地采纳的是用户的文件，绝不能删）。这条是防御性的，构造 insert
   失败的用例代价过高，**明确记为未覆盖**。
3. **`asset.replaced_in_place` 会以机器原文出现在活动记录里** —— 用户已就
   `asset.removed_external` 这类原文抱怨过。文案另算。

## 两个被否掉的想法（2026-08-21 用户提问，当场核过）

### ① 把 `originals` 改名成相册相关的名字 —— 不改

- 名字是**对的**：它跟 `.ppf/thumbs`、`.ppf/blobs`（派生数据）成对，
  `originals` = 原件。相册不是它，**相册是它里面的子目录**
- 改名是对所有存量库的破坏性变更：索引里每条 `rel_path` 都以 `originals/`
  开头、`rebuild::device_of` 按 `originals/<hex>/…` 解析、
  `list_asset_paths_under` 拿它做前缀、watcher 的监听根就是它
- 收益为零：用户从来不需要知道这个目录叫什么

### ② 将来加文件备份时，用软链把照片挂到 `files/` 下 —— 不做

理由见 `backlog/WATCH-06`。一句话：**视图活在查询里，不活在目录里。**
Android 的 `MediaStore.Images` 是一个查询而不是一个装满链接的文件夹；
`MediaStore.Files` 是全集，`Images`/`Video`/`Audio` 是它上面的过滤视图，
共用一套 `MediaColumns`。iOS 走的是另一条路（照片库对文件 App 完全不可见），
但我们已经是 Android 那一边了 —— 用户能在 Finder 里打开的目录。

加文件备份不是加第二个索引，是给现有索引加一个「种类」维度。只要 hash 是
唯一身份就不麻烦；一旦为文件另立一套 id，两边永远对不上。
