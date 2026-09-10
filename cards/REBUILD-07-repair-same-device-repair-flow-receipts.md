# REBUILD-07 同一设备重配对后 Flow receipt 不得占用新 epoch 队列

> 🟡 状态：代码完成，待同机重配对真机验收
> 级别：L2 · 阻塞：无

## 问题

用户在 Desktop 移除一台 Android 设备后，用**同一次安装**重新扫码。手机持久
NodeId 不变，因此 Desktop 正确地将它恢复为同一设备并生成新的 pairing epoch；
Android 的新 Flow ledger 同时从 `queue_sequence = 1` 重建。

但 `flow_delivery` 现以 `(node_id, queue_sequence)` 为主键，旧 epoch 已完成的
receipt 占用序号而且不可覆盖。新 epoch 同序号的 `flow.offer` 被
`matching_grant()` 视为 guard mismatch，手机只得到 `err.not_authorized`，无法继续传输。

这不是新设备的身份合并问题：稳定 NodeId 仍必须保持既有照片的来源关联；错误是
把一次配对生命周期内的临时队列序号误当作设备级永久身份。

## 期望行为

同一 NodeId 重配对后：

- 旧 epoch 的 receipt 历史和既有 asset `src_device` 关联保留；
- 新 epoch 可以从 `queue_sequence = 1` 正常 offer/fetch；
- old/new epoch 的同序号 grant 相互隔离，旧 epoch 的请求仍不能越过当前配对 epoch；
- 同一 epoch 内的 lease/hash/provider 精确守卫与 completed receipt 重放语义不变。

## 验收标准

- [x] schema migration 将 Flow grant 身份限定为 `(node_id, pairing_epoch, queue_sequence)`，已存在库升级不丢 receipt。
- [x] RED→GREEN：同一 NodeId 的旧 epoch `completed` 序号 1 存在时，切换到新 epoch 后同序号 1 的 offer 可建立独立 grant；旧 receipt 仍可按旧 epoch 读取。
- [ ] 反证：临时移除 epoch 维度后，上述同序号重配对用例必红。
- [x] 当前 epoch 以外的 offer/fetch 仍返回 GuardMismatch；同 epoch recovered lease 的 completed receipt 仍可重放。
- [x] `cargo nextest run -p storage`、`cargo nextest run -p daemon --test flow_delivery` 与 `just ci` 全绿。
- [ ] 真机：移除同一手机→重扫→连续传照片，新的 Flow 队列不因旧 receipt 而出现 `err.not_authorized`；随后继续 BLOB-01/02 的真实 GC 回归。

## 范围

- 只准动：`crates/storage/migrations/`、`crates/storage/src/flow_delivery_repo.rs`、`crates/daemon/src/flow_delivery.rs`、对应 Rust tests、卡片/索引/进度账本。
- 不准动：Android NodeId/IdentityStore 语义、设备/asset 归属、Flow protocol 字段、BLOB-01/02 的 GC 策略。

## 阻塞与依赖

无。真机验收使用同一设备重配对的已发现现场；BLOB-01/BLOB-02 回归在本卡可传输后继续。

---

## 根因与决策

NodeId 是稳定设备身份；pairing epoch 是一轮授权生命周期；queue sequence 仅在这
轮授权内有意义。三者的持久键必须一致。旧 schema 缺少 epoch，导致完成 receipt 的
不可变约束在重配对后错误阻塞新生命周期。

不通过删除旧 receipt 止血：那会丢失可审计的传输历史，也会把 schema 缺陷留在下一次
重配对。

## 实施记录（2026-09-10）

- `0004_flow_delivery_pairing_epoch_key.sql` 将既有 rows 原样拷贝到以
  `(node_id, pairing_epoch, queue_sequence)` 为主键的新表，再原子替换旧表；不触碰
  `asset.src_device` 或 device roster。
- `FlowDelivery` 的 grant/receipt 查询均显式带 epoch；同 epoch 的 completed receipt
  仍只能由相同 hash 的 recovered lease 重放。
- RED：`rejoined_device_reuses_a_sequence_in_its_new_pairing_epoch` 在旧 schema 实测
  `GuardMismatch`；GREEN 后该真实 iroh provider/receiver 流程通过，并断言新旧两张
  indexed asset 都保留。
- 验证：`cargo nextest run -p storage` **24 passed**；
  `cargo nextest run -p daemon --test flow_delivery` **8 passed**；`just ci` all green。