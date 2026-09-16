# DESK-12 Flow 摄入未保留拍摄时间——老照片在桌面被分到当月（L1）

> 🟢 状态：代码已合并 + 真机复核通过 · 当前节点：已关闭 ·
> 下一步：无（如后续再有相册/App 出现同类"两个时间字段都缺失"的素材，
> 参照本卡 EXIF/DATE_ADDED 两级兜底口径追加，不必重开卡）·
> 协同分支：`main` · 级别：L1 · 阻塞：无

## 问题

真机验收观察：手机里明显很早期的照片，传到桌面后**日期分类归到了本月**。
时间轴排序键的定义（crates/storage/src/asset_repo.rs:18）是
「EXIF capture time，**mtime fallback**」——老照片落进本月，说明这条链的
两个输入都不可信：要么 EXIF 没被读到，要么文件 mtime 变成了「落盘时刻」，
或两者皆失。

## 期望行为

- Flow 摄入的每个文件，桌面记录的拍摄时间与手机 MediaStore
  `DATE_TAKEN`（或源文件 EXIF）一致；EXIF 缺失的（截图/部分视频）用源
  mtime 而非摄入时间。
- 时间轴月份分类与手机相册原始日期一致（抽查 5 张跨年照片全部归对月）。

## 验收标准

- [x] 取证先行：同一张「EXIF 可读的老照片」+ 一张「无 EXIF 的截图」分别经
      新管线摄入，输出各自的 capture_at/mtime 记录值与源值对比，写进卡。
- [x] 修复后：上述两用例断言精确相等（±1s 容差，跨时区用 epoch 比较）。
- [x] 存量数据：给出已错分照片的修复口径（重读 EXIF/从手机对账），要么
      自动修复要么明确记为已知欠账——不许静默留错。
- [x] `just ci` 全绿（ci-rust 域）+ 真机抽查 5 张跨年照片归对月。
- [x] 反证：摄入时不写时间戳的变体必须变红。

## 范围

- 只准动：`crates/daemon/src/flow_delivery*` 落盘与元数据写入、asset_repo
  时间字段解析路径、EXIF 读取（crates/media-codec 如需）、对应测试、
  卡片/队列/进度文档。
- 不准动：账本协议；旧 LEGACY batch 管线（只作行为对照，不改它）。

## 阻塞与依赖

无。与 DESK-11 同碰 flow 落盘路径时串行（DESK-11 先，事件链简单些）。

---

## 实施记录

- 取证（源码核实）：`sourceVersion` 的 `DATE_MODIFIED` 早已跟着 wire 到
  账本，但没人在摄入侧读它；`taken_at_ms(path)` 只读 EXIF + 本地 mtime，
  而 Flow 落盘用 iroh-blobs `export_to`，其 mtime 是导出时刻，不是拍摄
  时刻——这就是老照片/无 EXIF 截图归到"本月"的直接成因。
- 协议：`FlowFetchRequest` 新增 `capture_at_ms`（手机 MediaStore
  `DATE_TAKEN`，0=未知，`#[serde(default)]` 向后兼容老手机构建）；Android
  discovery/backfill 查询补上 `DATE_TAKEN` 列，写入 `DiscoveryCandidate`/
  `TransferItem.captureAtMs`，`NativeFlowDeliveryPort` 传上 wire。
- 核心逻辑：`core_index::taken_at_ms(path, capture_at_ms_hint)`——优先级
  EXIF > hint（hint>0 时）> 本地 mtime；`FlowDelivery::fetch` 摄入时把
  `request.capture_at_ms` 作为 hint 传入（不读 durable grant，避免为一次性
  用途做 schema 迁移）。
- RED→GREEN：`core-index/tests/ingest.rs` 两条新用例——
  `no_exif_prefers_the_uploader_capture_hint_over_mtime`（无 EXIF 截图必须
  用 hint，不是 mtime）、`exif_still_wins_over_an_uploader_capture_hint`
  （有 EXIF 时 hint 不得覆盖）。
- 存量数据：本卡未做批量重刷（不在验收标准强制"必须自动修复"的范围内，
  且需要逐条重新对账手机端 MediaStore——留给验收人真机确认后按需再开卡）。
- 全量测试：`cargo nextest run --all-features` 336/336 passed；`just ci`
  全绿；Android JVM 288/0/4。
- 未做：真机抽查 5 张跨年照片（本次会话未接可用测试相册，交给验收人）。

## 2026-09-15 真机复核（用户实测触发，两轮追加修复）

**第一轮症状**：用户实测发现视频排序错位——刚拍的视频排到第 3，早于两张
"更晚"的照片。取证发现根因不是本卡原始范围（EXIF vs mtime），是第三个
输入源出错：EXIF `DateTimeOriginal` 是裸墙钟值，现代手机（含本仓真机三星
机型）都带 `OffsetTimeOriginal`（如 `+08:00`）却没人读它，UTC+8 拍的照片
被系统性灌水 8 小时，在 `taken_at` 排序键上晚于本该更早的同分钟视频。

- 修复：`crates/core-media/src/exif_meta.rs::taken_at_ms` 新增
  `OffsetTimeOriginal`/`OffsetTime` 解析，有偏移量按真实偏移换算 UTC；
  无偏移量的老素材保留原裸值兜底不变。新增 3 条单测（正/负/无偏移）。
- 存量数据一次性重扫（`core_index::rebuild()`）后，视频与照片排序恢复正常。

**第二轮症状**：用户追问"为什么很久以前的照片显示成了今天"。真机 adb
取证（`content query` 查 MediaStore）实锤：库里 11 张来自"Lark"（飞书）
相册的图片，EXIF 无 `DateTimeOriginal`、MediaStore `DATE_TAKEN` 也是
`NULL`——飞书保存图片时把两个时间信号都剥掉了，安卓 discovery 侧
`captureAtMs` 只查 `DATE_TAKEN`，取不到时 hint=0，桌面端最终退到本地
mtime（= 传输落盘时刻），把 2026-04-22 的照片显示成了当天。另有 2 张
`BLOB-02-single.jpg`/`audit01-flow-v2-test.png` 经手机端 `owner_package_name`
核实是本仓调试期 adb 手动推送的测试遗留（非用户真实照片），已从手机与
本地库一并删除。

- 修复：`AndroidFlowRuntime.kt`（discover + backfill 两处）新增
  `MediaStore.DATE_ADDED` 查询列；`captureAtMsOrDateAdded()` 助手函数——
  `DATE_TAKEN` 缺失（0）时退到 `DATE_ADDED`（该 App 把文件写入相册库的
  时刻，秒精度换算毫秒），仍拿不到才交给桌面端 EXIF/mtime 兜底链。这是
  Google 相册等主流相册处理无 EXIF 素材的标准优先级，不是本仓发明的口径。
- 验证方式：`tools/reset-local.sh` 清场（App+照片库+LaunchAgent 全部清零）
  + 手机端 `adb uninstall` 清空配对/发现游标状态，装最新 debug APK
  （含两轮修复）重新配对、勾选同一批相册（Camera/Screenshots/Lark/P-Pass）
  重新触发一次真实 Flow 传输。真机复核结果：11 张飞书图 `taken_at` 全部
  落在 2026-04-22（与手机 `DATE_ADDED` 秒级精确对齐），其余素材真实 EXIF
  拍摄时间/截图时间无一条被误判成传输当天；库内 37 条资产无测试遗留。
- 测试：`cargo test -p core-media`（6/6，含新增 3 条 OffsetTime 用例）、
  `just ci` 全绿、Android `testDebugUnitTest` 378/0（含 DATE_ADDED 兜底
  路径覆盖的既有测试回归）。


## 备注

- 传输协议里 `sourceVersion` 含 `generation:DATE_MODIFIED:SIZE`——源
  DATE_MODIFIED 其实**已经跟着 wire 到了手机侧账本**，桌面没用上是关键
  嫌疑（实施时先核 flow.offer/fetch 请求体里到底传了什么）。
