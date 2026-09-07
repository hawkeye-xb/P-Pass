# DESK-12 Flow 摄入未保留拍摄时间——老照片在桌面被分到当月（L1）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：等真机复核 ·
> 下一步：抽查 5 张跨年照片（含无 EXIF 截图）归月是否对 · 协同分支：`main`
> 级别：L1 · 阻塞：无

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

- [ ] 取证先行：同一张「EXIF 可读的老照片」+ 一张「无 EXIF 的截图」分别经
      新管线摄入，输出各自的 capture_at/mtime 记录值与源值对比，写进卡。
- [ ] 修复后：上述两用例断言精确相等（±1s 容差，跨时区用 epoch 比较）。
- [ ] 存量数据：给出已错分照片的修复口径（重读 EXIF/从手机对账），要么
      自动修复要么明确记为已知欠账——不许静默留错。
- [ ] `just ci` 全绿（ci-rust 域）+ 真机抽查 5 张跨年照片归对月。
- [ ] 反证：摄入时不写时间戳的变体必须变红。

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


## 备注

- 传输协议里 `sourceVersion` 含 `generation:DATE_MODIFIED:SIZE`——源
  DATE_MODIFIED 其实**已经跟着 wire 到了手机侧账本**，桌面没用上是关键
  嫌疑（实施时先核 flow.offer/fetch 请求体里到底传了什么）。
