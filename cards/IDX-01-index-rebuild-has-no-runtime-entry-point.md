# IDX-01 索引重建没有任何运行时入口——索引一丢，照片就永久看不见

状态：🟥 挂号
级别：L2（猜测；字节没丢，缺的是"把它们找回来"的路径）
关联: 与 [DEV-02](DEV-02-device-row-must-not-be-hard-deleted-on-merge.md) 互相放大

## 挂号段

- **现象**：库里 `originals/` 下有 24 个文件，索引里只有 13 行资产——
  某台旧手机身份（`d9b69ede…`）整整 11 个文件在桌面照片列表里完全不可见。
  `core-index` 里 `rebuild()` 实现完整、有 T-012 契约测试（"删库 → 重建 →
  dump 一致"），但**全仓零生产调用点**：对端协议 `crates/proto/src/msgs.rs`
  的方法常量表和本地 IPC `crates/daemon/src/ipc.rs` 的分派表里都没有对应
  方法，桌面也没有入口。ADR-006「originals 是真相，索引可重建」这条铁律
  在**运行时没有执行路径**——只有测试能调它。
- **发现场景**：2026-09-17 NET-24/BUILD-05 收尾后，验收人发现桌面照片列表
  只有 13 张、而自己传过的远不止，要求本地取证。
- **严重度猜测**：高。字节没丢（ADR-006 的保底部分生效了），但用户看不见
  = 产品承诺失效，且当前**没有任何自助恢复手段**——只能改代码或手改数据库。

## 备注（挂号时已核实，供接卡人省一次考古）

**本次索引为什么是空的（已排除误判）**

- 当前 `index.sqlite` 的 6 条迁移 `installed_on` 全是 `2026-09-16 10:38:39`
  （UTC；`datetime(installed_on,'localtime')` = **18:38:39**），`identity.key`
  的 mtime 同为 18:38——索引与桌面身份是那一刻**新建**的。
- `d9b69ede…` 的 11 个文件落盘时间是同日 **15:12**，比当前索引早三个半小时；
  最早的 `ingest.new` 审计是 **18:41:20**。这批文件属于上一代索引，重建时
  没人把它们带过来。
- **合并路径可排除**：审计是 append-only，但 `audit_operation` 里 actor 只有
  `9E413C24`/`BE03D1D1` 两个，`d9b69ede` 零痕迹；13 行资产的 `rel_path` 目录
  名也与各自 `src_device` 一一对应（`merge_device()` 改挂 `src_device` 却不改
  `rel_path`，真发生过就会错位）。所以不是 DEV-02 那条路造成的。

**rebuild 能不能救回来——已实测**

`rebuild()` 对文件系统是只读的（只 `hash_file` / `fs::metadata` / 读 EXIF，
写只发生在 DB）。把它指向**真实库根 + 一个内存索引**跑了一次（用户库零写入，
跑完复查 `asset` 仍是 13 行、`index.sqlite` mtime 未变）：

    REPORT indexed=23 duplicates=1
    TOTAL rows=23
    DEV 9e413c24738eb46a -> 11
    DEV be03d1d1050fbfb8 -> 2
    DEV d9b69edef7ae2c1e -> 10

跑之前先下的预测与结果逐位吻合：两份 `screen_state_check.png` 内容相同
（md5 `fe88aede43d3d7662bd7f5f0c4b18d85`），`collect_files` 按字典序排、
`be03d1d1…` 排在 `d9b69ede…` 前面，所以 be03 那份赢得索引行、d9b69ede
那份计为 duplicate → **23 + 1**，而不是 24 + 0。`.DS_Store` 被跳过。

**接卡人要拿的拍板（本卡不替验收人决定）**

1. 入口做成什么形状：桌面一个「重建索引」按钮 / 本地 IPC 方法 / daemon 子命令。
2. 要不要自动对账：启动时比一次 `originals/` 文件数 vs 索引行数，不一致就提示。
   （全量 `rebuild()` 开头是 `db.clear_assets()`，自动跑要先想清楚失败中断的后果。）
3. `rebuild()` 会把 `added_at` 重置为重建时刻、`width/height` 置空、
   `thumb_state` 归 0——这些漂移模块头注释已列明，是否可接受要确认。
