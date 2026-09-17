# DEV-02 设备记录不得被物理删除——解绑/身份替换只允许标记「已断开授权」

状态：🟥 挂号
级别：L2（猜测；改存储语义 + UI 要能显示这个新状态）
关联: 收紧 [DEV-01](done/DEV-01-identity-survival-and-merge.md) 的合并语义 ·
与 [IDX-01](IDX-01-index-rebuild-has-no-runtime-entry-point.md) 互相放大 ·
邻居 [MOB-64](MOB-64-revoked-device-gets-no-feedback-until-next-attempt.md)（同一事实的手机侧反馈）

## 挂号段

- **现象**：`crates/storage/src/device_repo.rs:224`，`merge_device()`
  （DEV-01「替换旧的」路径）把 `asset.src_device` 改挂到新身份后，执行
  `DELETE FROM device WHERE node_id = ?` **物理删除**旧设备行，连同
  `DELETE FROM backup_watermark`。删完之后旧身份在 `devices.list`、设备页、
  活动/审计投影里都查无此人，只能翻 append-only 审计流考古。
  验收人拍板（2026-09-17 原话）：「本地的数据只能通过本地删。如果移动设备
  在远端解除绑定之后，我们本地接收到信息，可以把它标记为已断开授权，或者
  没接收到信息也行，但本地不应该把这个设备的记录删除掉。」
- **发现场景**：2026-09-17 排查 IDX-01「10 张照片不在列表」时读
  `device_repo.rs` 撞见。**本次照片丢失不是它造成的**（IDX-01 卡里已列反证），
  它是独立的同类缺陷。
- **严重度猜测**：中偏低（当前潜伏，见备注第一条）。照片行是改挂不是删除，
  数据面不丢；丢的是「这台设备存在过」这个事实。与 IDX-01 互相放大：
  `rebuild()` 从目录名反推 `src_device`，所以重建之后必然产出一批
  `device` 表里查无此人的资产。

## 备注（挂号时已核实，供接卡人省一次考古）

- **这条路当前是潜伏的，不是每天在跑**：[DEV-01b](done/DEV-01b-hide-merge-entry.md)
  （验收人 2026-08-12 拍板）已把桌面「替换旧的 X」入口用默认关的开关藏起来，
  现阶段统一走「重新扫码 = 全新授权」。所以 `merge_device()` 眼下**没有 UI
  可达路径**——这降低紧急度，但开关一打开缺陷就在，且底层 `device_hint`
  仍在照常积累、就是为将来打开它准备的。
- **手机主动解绑那条路已经是对的，不要顺手改**：`device.unpair`
  （`router.rs:828` `handle_unpair`）走的是 `revoke()`，即
  `UPDATE device SET revoked = 1`；`crates/daemon/tests/pairing_flow.rs:270`
  有断言 `"device row must be revoked after unpair"`。桌面端点击「移除」
  同理（`ipc.rs:749` `device.revoke`）。**唯一物理删除点就是 `merge_device()`。**
- 存储层已有完整的软删语义可复用：`revoke()` / `unrevoke()`，
  且 `upsert_device` 故意不清 `revoked`（防误触，T-010 测试）。
- 现状只有 `revoked` 一个布尔位，而验收人要的「已断开授权」与现有
  「已吊销」是不是同一个状态，需要拍板：复用 `revoked=1` 最省事，但会让
  设备页分不清「我主动移除的」和「对方自己解绑的」——而 MOB-64 正是在
  给手机侧补这个区分的反馈，两边口径应当一致。
- 改完以后 `devices.list` / 设备页要能显示这一行而不是让它消失，否则
  「不删记录」在用户眼里和删了没区别。
