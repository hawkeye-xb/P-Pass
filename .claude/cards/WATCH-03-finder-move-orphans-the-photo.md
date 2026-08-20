# WATCH-03 在 Finder 里挪动照片，索引把行删了，照片凭空消失　级别 L1

> 🟡 已合并，等真机验收。修 WATCH-02 时顺手挖出来的，比 WATCH-02 更严重。

## 现象

用户在 Finder 里把 `originals/<device>/2026/08/IMG_E.jpg` 拖进自建目录
`originals/我的婚礼/`（就是**给照片分类**这个最自然的动作）：

- 文件还老老实实在盘上
- 但**索引里那一行被删了** → 照片墙上消失、手机时间线上消失
- 而且**再也回不来**：没有新的文件系统事件了，谁也不会去重扫

比 WATCH-02 严重：WATCH-02 是「删了但没消失」（多显示），这条是「没删但消失了」
（**用户以为自己弄丢了照片**）。

## 根因

`watcher.rs` 的 `process` 先跑新增方向、再跑删除方向：

1. `ingest_new` 在新位置发现这份内容 → hash 已在索引里 → 返回 `Duplicate`，
   **不更新 `rel_path`**（索引还指着旧住址）
2. `reconcile_under` 枚举旧目录 → 旧路径不存在 → **删行 + 删缩略图 + 记审计
   `asset.removed_external`**

两步各自都"对"，合起来是数据不可见。**根本问题是身份口径**：内容寻址系统里
hash 才是身份，`rel_path` 只是「当前住址」。搬家不该销户。

## 改动

`crates/core-index/src/ingest.rs` —— hash 命中时**先看记录的文件还在不在**：

| 记录的文件 | 来源位置 | 结果 |
|---|---|---|
| 还在 | 任意 | `Duplicate`（原样，来源文件不动） |
| 不在了 | 已在 `originals/` 树内 | `Moved(rel)` —— **就地采纳**用户摆的位置 |
| 不在了 | 库外（staging，手机重传） | `Moved(rel)` —— 按 canonical 布局落位 |

新增 `IngestOutcome::Moved(String)` + `Db::update_asset_rel_path` + 审计动作
`asset.relocated`。

顺带补掉一个既有的洞：**手机重传一张曾被外部删掉的照片**，旧代码返回
`Duplicate` → staged 文件被删、索引行仍指向不存在的文件 → 下一轮对账把行也删
掉，照片永远补不回来。现在会正常落位。

⚠️ `rel_inside_originals` 两侧都必须 `canonicalize`：macOS 上 `/var` 是
`/private/var` 的符号链接，watcher 的监听根做过 canonicalize 而 `library_root`
没有，不规范化 `strip_prefix` 永远失败 → 库内移动被误判成「来自库外」→
**文件被搬回日期目录**（用户的分类被我们抹掉）。

## 验收证据

反证（把修复改回去，对应测试必须变红）：

```
✅ M3  hash 命中一律当重复            → move_inside_originals_repoints_the_row_in_place FAILED
✅ M3b 同一处 → 库内移动丢行           → moving_a_file_inside_originals_keeps_it_indexed FAILED
✅ M4  不认库内位置（丢 canonicalize） → moving_a_file_inside_originals FAILED
                                       （panic: 用户放的位置不该被我们动）
```

新增测试：

- `core-index`: `move_inside_originals_repoints_the_row_in_place`（断言 rel_path
  改指 `originals/我的婚礼/…` 且文件没被搬走）
- `core-index`: `reupload_of_an_externally_deleted_photo_lands_in_canonical_layout`
- `core-index`: `duplicate_stays_duplicate_while_the_recorded_file_is_present`
  （反向守卫：文件在位时必须仍是 `Duplicate`，否则正常重传路径的源文件会被误移走）
- `daemon`: `moving_a_file_inside_originals_keeps_it_indexed`（端到端，走真
  FSEvents；只数行数会漏掉「指向哪里」，所以同时断言 `rel_path` 与文件真实存在）
- `storage`: `rel_path_can_be_repointed_without_touching_identity`

## 遗留：性能（未做，等拍板）

现在识别「移动」靠**重算 hash**。用户一次拖 5000 张进新目录 = 重读 5000 个文件。
正确但不便宜。

省掉这一步需要一层身份缓存：把 `(dev, inode, size, mtime)` 存进索引，stat 没变
就不重算 hash；Finder 的移动**保留 inode**，可以直接判定为移动。这是 schema 变更，
另立卡。

## 遗留：产品语义（未做，等拍板）

**用户新拖进 `originals/我的相册/` 的照片（索引里还没有的），要不要被我们搬到
`originals/<device>/2026/08/`？**

- 现在的行为：**会搬**（`place()` 无条件按日期布局落位）
- 已修的部分只覆盖「索引里已有这份内容」的情况

这是产品决定，不是 bug，没动。
