# IDX-01 索引重建没有任何运行时入口——索引一丢，照片就永久看不见

状态：✅ 已归档——真库 E3 通过（2026-09-17，10 张照片自己回来了）
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
- **严重度猜测**：高。**这 24 个文件**的字节没丢（ADR-006 的保底部分生效了），
  但用户看不见 = 产品承诺失效，且当前**没有任何自助恢复手段**——只能改代码
  或手改数据库。⚠️ 「一个字节都没少」这句话**不成立**，见下方未决问题①。

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

**两个还没答案的问题（挂号时诚实登记，不要当成已知）**

1. **磁盘上这 24 个是不是全部？** 验收人原话是「远远不止 13 张」，而磁盘只有
   24 个（约 2 倍，算不算"远远不止"没确认）。当前 `flow_delivery` 的 59 行
   全 completed、13 个去重后的 content_hash 全都在 `asset` 表里——**但这张表
   本身就是 18:38 之后建的，它结构上无法为 18:38 之前的历史作证**。也就是说
   「d9b69ede 传过的东西有没有一部分连字节都没落盘」这个问题，本地现有数据
   回答不了，要么问验收人当时传了多少，要么去手机侧账本比。
2. ~~**索引是被什么删掉的？**~~ **已查清（2026-09-17 验收人确认「重装时清理」）**：
   是人工清理，不是产品自己干的。三条互不依赖的证据——
   ① 产品内**没有**删除路径：全仓 `remove_file`/`remove_dir_all` 只出现在
   staging/缩略图清理，没有一处碰 `.ppf/` 或 `identity.key`；`folder.set`
   （`ipc.rs:890`）只写 `config.toml`、不动旧库；`main.rs:550` 在
   `identity.key` 缺失时**新建**一把，正是 18:38 那一刻的现象。
   ② 回放 09-16 10:15–10:50 UTC（含 10:38:39 那一刻）全部 39 条 agent 命令，
   **一条写操作都没有**，10:35–10:43 之间更是完全空档。
   ③ 仓里唯一的清场脚本 `tools/reset-local.sh` 是 `rm -rf` 整个照片库目录
   （**连 `originals/` 原图一起删**），它要是跑过，这 24 个文件不会还在。
   **所以当时删的只有 `.ppf/`，`originals/` 完整留下——这正是 ADR-006
   设计时就认定的正常场景，不是"清理没清干净"。缺的是清理之后把照片重新
   认领回来的那条路，也就是本卡。**

**~~接卡人要拿的拍板~~（已在下方可接段全部拍完，保留原文供追溯）**

1. 入口做成什么形状：桌面一个「重建索引」按钮 / 本地 IPC 方法 / daemon 子命令。
2. 要不要自动对账：启动时比一次 `originals/` 文件数 vs 索引行数，不一致就提示。
   （全量 `rebuild()` 开头是 `db.clear_assets()`，自动跑要先想清楚失败中断的后果。）
3. `rebuild()` 会把 `added_at` 重置为重建时刻、`width/height` 置空、
   `thumb_state` 归 0——这些漂移模块头注释已列明，是否可接受要确认。


## 可接段

**context**

挂号时把问题描述成"`rebuild()` 没有入口"，读完相邻模块后**范围要更正**：
真正的缺口不是"缺一个按钮"，是**启动对账只有一个方向**。

- `Reconcile`（SYNC-01，`reconcile.rs:78` `run_once`）遍历的是 **asset 行**，
  判据是 `!library_root.join(rel_path).exists()` → 删行。也就是只做
  「磁盘没了 → 清索引」，**不做**「磁盘有、索引没有 → 收编」。启动跑一轮 +
  每小时一轮（`main.rs:441-459`）。
- `LibraryWatcher`（WATCH-01）**两个方向都有**（新增 → `Ingestor::ingest`
  就地采纳；删除 → 复用 `Reconcile::remove_asset`），但它是 notify 事件驱动，
  `spawn()`（`watcher.rs:114`）只装监听、**不做首次扫描**。所以 daemon 启动
  *之前*就躺在磁盘上的文件永远等不到事件。
- 于是「索引被清掉、originals 留着」这个 ADR-006 明确认定的正常场景，
  运行时没有任何一条路能收敛——这才是 10 张照片看不见的完整机制。

**`rebuild()` 那个循环本身就是增量收编**（`rebuild.rs:71-73`）：
`hash_file` → `if db.get_asset(&hash).is_some() { duplicates += 1; continue; }`
→ 否则 insert。对着**非空**表跑，它只会补缺失的。整个函数里唯一破坏性的
一行是开头的 `db.clear_assets()`；而 `clear_assets` 想覆盖的方向（行在、
文件没了）**`Reconcile` 已经在做了**。所以本卡不需要清表。

**四项前置已核实（决定了自动收编是安全的）**

1. **没有任何产品路径会「删索引行但留文件」**——全仓删 asset 行只有三处：
   `reconcile.rs:87`（`!exists()` 才删）、`watcher.rs:314`（同样先 filter
   `!exists()`）、`ingest.rs:201`（同路径内容被改写，旧 hash 的内容确实已不在
   磁盘上）。`audit_tombstone.reason` 里的 `product_delete` 全仓只出现在一句
   文档注释里，表中 0 行。**所以自动收编不可能把用户删掉的照片复活**——
   这是本卡敢做成自动的前提，接卡人若发现新增了删除功能必须回头重估。
2. `timeline_page`（`asset_repo.rs:260`）是纯 `FROM asset`，**不 join `device`**
   ——收编出来的 `src_device` 在 `device` 表里查无此人也照常渲染（这正是
   [DEV-02](DEV-02-device-row-must-not-be-hard-deleted-on-merge.md) 那条
   互相放大的关系，本卡这边不受阻）。
3. 缩略图**按需生成**（`query.rs:112-128` miss 时现场生成并回写 `thumb_state`），
   `thumb_state=0` 只是缓存提示，不会显示成碎图。
4. `insert_asset`（`asset_repo.rs:54`）**撞 hash 直接报错**，注释写明"重复 =
   逻辑 bug"。一次性的 `rebuild()` 没有并发所以无所谓，但收编要和 ingest
   长期并存，`get_asset` 与 `insert` 之间的窗口是真的——必须按"别人先到"
   处理，不能让一次竞态把整轮收编打断。

**问题**

库里 `originals/` 下有 24 个文件，索引只有 13 行（注：该计数为 09-17 上午
取证时的状态），某台旧手机身份 `d9b69ede…` 的 11 个文件在桌面照片列表里
完全不可见。复现：删掉 `.ppf/index.sqlite` 后重启 daemon——照片全在磁盘上，
一张也回不来。

**期望行为**

「originals 是真相，索引可重建」（ADR-006）在**运行时**成立：索引缺了行而
文件还在，daemon 自己收敛，不需要用户做任何事、也不需要改代码。

**修法（已拍板，接卡人照做；偏离要先改卡）**

1. `rebuild.rs` 把那个循环抽成共用函数，`rebuild()` = `clear_assets()` + 循环
   （**行为不变，T-012 继续守着它**），新增 `adopt_orphans(db, library_root,
   local_node_id) -> AdoptReport` = 只跑循环、**不清表**。归属沿用同一个
   `device_of()`（`originals/<64hex>/` 反推，否则本机）。
2. `Reconcile::run_once` 在现有删除方向之后补上收编方向，启动一轮 + 每小时
   一轮自动跑——与 SYNC-01 同构，不新开调度。
3. 收编 0 条时**不写审计**（WATCH-07 的噪声纪律：每小时一条"收编了 0 条"
   就是刷屏）。
4. **本卡不做桌面按钮。** 自动收敛已经解决了报告的问题，加 UI 是额外范围、
   额外风险，而验收人定的调是"先讲究快速"。真要手动入口另开卡——这条是
   本卡替验收人做的判断，要否决就现在否。

**验收标准**

- [ ] `rebuild()` 对外行为一字不变，T-012（`core-index/tests/rebuild.rs`）仍绿 [E1]
- [ ] 收编**不清表**：跑完之后原有行的 `added_at`/`width`/`height`/`thumb_state`
      逐字段未变（这是"没有偷偷走 clear+rebuild"的硬判据）[E1]
- [ ] 竞态：`get_asset` 未命中但 insert 撞 hash 时按"别人先到"跳过，整轮不失败 [E1]
- [ ] 收编 0 条不写审计行 [E1]
- [ ] `just ci` 绿 [E1]
- [ ] **真库 E3**：daemon 重启后，桌面照片列表**肉眼可见**多出那 10 张
      （只验 SQL 不算——第 2 条前置说的就是"可能查得到但渲染不出来"）[E3]
- [ ] **反证①**（故障判据，去掉故障条件必须变红）：停掉收编那一步 → 10 张
      仍然不可见 [E3]
- [ ] **反证②**（不越界）：收编跑完，原有行的 `added_at` 全部未变；若走了
      清表重建，这条必红 [E1]

**范围**

- 只准动：`crates/core-index/src/rebuild.rs`、`crates/core-index/src/lib.rs`
  （导出）、`crates/daemon/src/reconcile.rs`、`crates/daemon/src/main.rs`
  （只为把 `local_node_id` 递给对账）、对应测试、版本号、卡/QUEUE/PROGRESS。
- 不准动：`rebuild()` 的对外契约与 T-012；`Reconcile` 删除方向的语义与审计
  口径；`clear_assets()` 的调用面（除 `rebuild()` 外仍须保持零生产调用）；
  `Ingestor`/watcher；桌面与手机 UI；**照片库原图任何情况下不可动**。

**阻塞与依赖**

- 无。验收人已明示本期数据可删、可重装，真库 E3 取证不受限。


## 实施记录

**改了什么**

- `rebuild.rs`：把扫描循环抽成私有 `index_missing_files`，`rebuild()` =
  `clear_assets()` + 循环（**对外行为一字未改**，T-012 六条全绿），新增
  `adopt_orphans()` = 只跑循环、不清表，独立的 `AdoptReport
  { adopted, already_indexed }`（没有复用 `RebuildReport.duplicates`：清表后
  "跳过"只可能是"本轮已索引过的同内容副本"，增量下压倒性地是"早就在册"，
  同一个数字两种事实，共用字段名会让每个读小时报的人得出错误结论）。
  竞态处理：`insert_asset` 撞主键时**先回查** `get_asset`，确认对方真落了行
  才咽下这个错并计入跳过，否则原样上抛——不拿竞态当万能借口。
- `reconcile.rs`：`run_once` 补上收编方向，`ReconcileReport` 加 `adopted`；
  新建造者 `with_local_node_id` 作为开关（`watcher.rs` 借用 `remove_asset`
  的那一份不接，不该顺带扫全库）。收编失败只 `warn!` 不中断——与既有
  `list_asset_paths` 失败同一条纪律，对账绝不把 daemon 启动搞挂。
- `main.rs`：常驻对账器接上 `with_local_node_id(node_id.0)`。
- 版本 `0.5.4-test.6` → `0.5.4-test.7`，versionCode 27 → 28。

**为什么不查 `audit_tombstone`**（代码里也写了）：墓碑记的是"这份内容离开过
库"，而能走到收编这一步说明文件此刻确实躺在 `originals/` 里——那是有人把它
放回来了。按墓碑永久拉黑，会让"删了又放回来"的照片再也进不了库，比本卡要修
的问题更糟。

**测试（新增 9 条）**

- `core-index/tests/adopt.rs` 5 条：孤儿带原归属回来、第二遍空跑不改任何字段、
  在册行逐字段不动、空跑不写审计（WATCH-07 噪声纪律）、同内容两份只占一行且
  计入 `already_indexed`。**5 passed**
- `daemon` `reconcile::tests` 新增 3 条（共 6 passed）：收编生效、没接开关就
  一行不写、在册行不被重写。
- `daemon/tests/idx01_wiring.rs` 1 条：断言 `main.rs` 真的接了
  `with_local_node_id`——**这条专堵 DEVLOG-01 那个坑**（函数写好测好但生产没调，
  单测全绿而生产是死代码）。**1 passed**
- `core-index/tests/rebuild.rs`（T-012）**6 passed**，证明重构没动 `rebuild()`。

**反证三组，全部真跑**

| 反证 | 做法 | 结果 |
|---|---|---|
| ① 故障判据 | 停掉 `run_once` 里的收编调用 | `run_once_adopts_a_file…` + `adoption_never_rewrites…` **2 条变红** |
| ② 不越界 | 让 `adopt_orphans` 偷偷先 `clear_assets()`（退化成 rebuild） | adopt 5 条里 **3 条变红** + daemon 侧 1 条变红 |
| ③ 死代码 | `main.rs` 摘掉 `with_local_node_id` | 接线断言变红，报错原文即"否则只剩删幽灵那一半" |

三处均已还原，`git diff --stat` 复核只剩预期的 4 个文件。`just ci` 在版本 bump
之后跑过一遍，**all green**。

**真库 E3（2026-09-17，通过）**

构建产物清空后从零重建、完整打包、替换 `/Applications/P-Pass.app`、重启
daemon。装的是什么已核实：包内与安装后 daemon 均报 `0.5.4-test.7`，运行中
二进制 md5 `a31fa29d…` 与新构建逐字节一致，`lib/` 6 个，
`codesign --verify --deep --strict` 过。

**跑之前先下的预测**（36 个磁盘文件、25 行索引、11 个孤儿里有 1 份与
`be03d1d1` 内容相同的 `screen_state_check.png`，字典序 be03 已赢）：
索引 25 → **35**，`d9b69ede` 出现 **10** 行。

**实测逐位命中**：

    索引总数                35
    9E413C24738EB46A        11
    BE03D1D1050FBFB8        14
    D9B69EDEF7AE2C1E        10      ← 收编回来的
    审计 index.adopted      {"adopted":10,"already_indexed":26}

`already_indexed` 26 = 原有 25 + 那份重复副本 1，与磁盘 36 个文件闭合
（10 + 26 = 36）。

**看得见，不只是查得到**（这条判据存在的全部理由）：用桌面壳自己那条 IPC
（`App.svelte:664` 的 `timeline.page`）拉全量，返回 **35 张**，其中
`d9b69ede` **10 张**。另已核实 `photoWall.js` 只在变更检测里用 `src_device`、
不做任何设备过滤，所以"设备表里查无此人"不影响渲染。

**缩略图**（收编行 `thumb_state` 初值 0，必须走按需生成）：10 条全部请求
`thumb.get` → **10/10 成功**，首条回 11244 字节真 JPEG（`FFD8` 头），
请求后 10 条 `thumb_state` 全部变 1。不是碎图。

**媒体类型无漂移**：收编的 4 个 `.mp4` 在库里都是 `video/mp4`，与正常 ingest
的那个 `.mp4` 完全一致。（中途一度看到 `video` 而以为有漂移——那是 IPC 层
给 UI 的粗分类投影，不是库里的值，已核对更正。）

**反证①在真环境自然成立**：同一个库、同一批文件，整个会话里跑的
`0.5.4-test.6` daemon 始终是 25 行、那 10 张一直不可见；只换 daemon 到
test.7 重启后变 35。变量只有 daemon 一个。不需要另外构造残缺版本。

**顺带**（同卡范围内）：启动日志原本只报"移除幽灵资产 N 条"，收编跑了多少
一个字都没有——已改成
`SYNC-01/IDX-01: 启动对账完成（移除幽灵资产 N 条，收编孤儿文件 M 条）`；
每小时那轮同样补上，且沿用"只在真收编了才记"的噪声纪律。
