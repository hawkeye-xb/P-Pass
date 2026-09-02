# REBUILD-06 新 Flow 对新媒体的 offer/fetch 授权与回执一致性（L2）

> ✅ 状态：归档 · 协同分支：`main` · 前置：REBUILD-05
> 级别：L2 · 阻塞：无
> 当前节点：三星新队头完成、Pause / 重启 / Continue / Cancel 验收通过

## 问题

三星测试相册的范围补扫已将原先漏入账的 4 项推进到 `CONFIRMED`。随后向同一测试
相册加入一项用于 Pause 的大测试图片：该项进入 Flow 后第一次 `flow.fetch` 等待
15 秒无响应，第二次 `flow.offer` 被 Desktop 返回 `err.not_authorized`；手机严格队头
保持 `QUEUED`、attempt=2，而 Desktop 资产数与手机 confirmed 的不同 hash 数不再一致。

这不是范围、照片内容或 UI 状态问题；在授权过的配对会话中，新 Flow 项不应被拒绝，
且 fetch 回执超时后必须可判定地收敛。

## 期望行为

当前配对 epoch 的新队头能完成 `flow.offer → flow.fetch → durable receipt`；若网络超时，
重试保持同一 strict head 和幂等 Desktop 资产事实，不产生无法解释的手机/Desktop 差额。

## 验收标准

- [x] Desktop 日志与手机 Flow ledger 时间线给出 `err.not_authorized` 的具体授权判据；不以
  重新配对或清库掩盖根因。
- [x] 一项新增测试媒体在有效配对下得到 `CONFIRMED`，或以可见、可重试的失败终态收敛；
  手机与 Desktop 的 distinct content hash 数可解释一致。
- [x] 只用独立测试相册验证，不删除真实照片或重置既有测试账本。
- [x] REBUILD-04 的 Pause → 杀 App → 重开仍 Pause → Continue → Cancel 流程使用该修复后的
  可传队头完成。

## 范围

- 只准动：Flow offer/fetch 授权、回执幂等与诊断、对应 Android/Desktop/Rust 测试、真机验收记录。
- 不准动：REBUILD-05 的范围补扫语义、旧 batch/Worker、真实照片库数据、无关 UI。

## 阻塞与依赖

REBUILD-05 的 scope backfill 已在三星测试相册实测；需要当前三星与 Desktop 已配对会话的
可观察日志。`NET-01` 的 relay 15 秒超时是相关既有调查项，但本卡额外记录了 Desktop
明确返回 `err.not_authorized` 的授权拒绝，不能合并为单纯网络超时。

## 实施记录

- 真机状态证据：Android 当前 pairing epoch 与 ledger/item epoch 不一致；Desktop 当前
  grant 与 Android pairing epoch 一致，旧队头因此不具备再次 offer 的授权前提。
- 新增 `ensureCurrentEpoch`，runtime 建立时强制以当前 pairing epoch 清退旧队列、partial
  与 lease；失败回归 `stale_runtime_epoch_is_replaced_before_an_old_head_can_be_delivered`
  已通过，随后 pairing/runner focused JVM tests 与 debug APK 均成功。
- delivery 启动后再次在 offer、fetch 与 receipt 之前核对当前 pairing epoch；若运行中切换
  Desktop，旧 native provider 会撤销且不再把旧失败写入新 epoch ledger。RED：
  `FlowDeliveryEpochGuard` 缺失导致 pairing epoch 测试编译失败；GREEN：
  `ARCH01PairingEpochTest` 通过。
- 真机聚合证据：当前 Android ledger 为 30 `CONFIRMED` + 1 `QUEUED`，新队头两次
  `flow.offer` 均 `err.not_authorized`；Desktop 有 1 个有效 member、31 个 completed Flow
  grant，均匹配 Desktop 当前 grant epoch。`hello` 现仅向已认证 member 回传其 epoch；delivery
  preflight 发现差异即持久刷新 pairing、清退旧 Flow 状态并重新唤醒，不调用 re-pair 或清库。
- 进一步真机字段对账：queued #31 与 Desktop completed grant 的 epoch/content hash 相同，只有
  lease token 不同。完成回执的 identity 不可变，但恢复后的同 epoch + hash 允许原 receipt
  rebind 到新 lease/provider；不同 epoch/hash 仍严格拒绝。RED：recovered lease `offer` 返回
  `GuardMismatch`；GREEN：`verified_native_fetch_materializes_before_a_durable_receipt` 回放原 receipt。
- **最终三星验收**：更新 Desktop daemon 与 Android debug APK 后，新队头从 30 到 31
  `CONFIRMED`，`PPassFlow` 仅记录 epoch preflight 成功、无 `err.not_authorized`。Phone 当前
  32 个 `CONFIRMED` 的 31 个不同 hash 全部在 Desktop completed grants / assets 中；Desktop
  额外的 1 个同 epoch completed grant 是此前手机不再持有的历史 Flow 行，不影响当前队列
  或 receipt 收敛。随后用隔离测试相册生成的 512MB 文件复验 REBUILD-04 全流程：Pause、
  强杀重开仍 Pause、Continue 原队头、再次 Pause 后 Cancel Current Round；最终
  32 `CONFIRMED` + 1 `CANCELLED_BY_USER_ROUND`。
