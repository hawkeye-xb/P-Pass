# ARCH-08 P1 Desktop 存在性探测与分页协议（L2）

> ✅ 状态：代码完成；后续卡负责分页选择、源探针与账本裁决接线
> 级别：L2 · 前置：ARCH-07 · 协同分支：`main` · 基线：`12f2f63`
> 当前节点：为 ARCH-07 的账本事实提供 side-effect-free Desktop presence page；下一步：先写 daemon 协议失败合同。

## 问题

现有 `backup.manifest` 的裸 hash 路径虽然能返回缺失集合，却仍会创建/触碰按手机 NodeId 归属的 `BackupSession`。`BackupRunner.existCheck` 也属于旧批次校准和 `ConfirmedStore` 管线。把它们用于 ARCH-01 的低频对账会让只读观察混入上传会话状态，且没有明确的 500 项分页边界。

## 期望行为

新增受现有配对鉴权保护的只读控制面方法 `backup.presence`：请求为 `BackupPresenceQuery(hashes)`，响应复用只含缺失 hash 的 `BackupMissing`。每页最多 500 个 hash；daemon 仅查询索引，不创建或触碰 `BackupSession`、不写 audit/watermark/staging/blob，也不发起 fetch。Android 新 adapter 只将一个已确认内容 hash 页送往该方法并返回缺失集合；它不访问 MediaStore、不写 ARCH-07 账本、不调用旧 `BackupRunner`/`existCheck`。

本卡只解决“Desktop 对这一页 hash 的存在性事实”，不负责选择下一页、源探针、账本裁决、调度、重传或 UI。

## 验收标准

- [x] Rust proto 与 Android `Proto.kt` 对称新增 `BackupPresenceQuery` 及 `Methods.BACKUP_PRESENCE = "backup.presence"`；请求仅包含 hash 列表，响应仅为缺失 hash 列表。
- [x] daemon 仅对已配对成员接受 `backup.presence`；请求 1..500 个可解析 hash 时，返回其中索引缺失的 hash，顺序与请求一致。
- [x] 空页、超过 500 项或不可解析 hash 为 hard request failure，不得静默截断或产生部分事实。
- [x] presence 查询不创建/触碰 backup session，不写 audit/watermark/staging/blob，不调用 fetch/ingest；已有上传会话在查询前后等价。
- [x] Android `RemotePresenceProbe`（或等价薄 adapter）一次只提交一个校验过的 ≤500 hash 页，正确解析 missing 集合；不引用 `BackupRunner`、`ConfirmedStore`、`ReuploadQueue` 或 MediaStore。
- [x] 先写 daemon/Android 的失败合同；反证：把 handler 委托给 `manifest` 或接受 >500 项时，相关测试必须变红。
- [x] Rust/Android 相关测试和 `just ci` 通过；Android 测试报告本次 XML 数量、tests、failures/errors。

## 范围

- 只准动：`crates/proto` 的 presence query 消息/方法常量、daemon backup/router 的只读 query、对应 Rust 集成测试；Android Proto 与独立的 presence probe adapter/测试。
- 不准动：ARCH-07 的账本裁决、旧 `BackupRunner` / `existCheck` / `ConfirmedStore` 校准、WorkManager、MediaStore、UI、native fetch 上传/下载、现有 `backup.manifest` 语义。
- 不准用 `backup.manifest` 冒充 presence：该方法的会话副作用是本卡要消除的风险。

## 阻塞与依赖

ARCH-07 已提供持久内容身份及 `RemotePresence` / `SourcePresence` / `RecoveryDisposition` 账本字段。无外部阻塞。

后续卡负责按 queueSequence 对 `CONFIRMED` 项分页、调用本 adapter、只在 `MISSING` 后探测手机源并调用 ARCH-07 的裁决；UI 卡才可展示决策。

---

## 实施记录

- 2026-09-01：从 ARCH-01 P1 的“低频分页检查已确认 hash 是否仍在 Desktop”边界拆出并认领。代码勘查确认 `backup.manifest` 的 bare-hash 分支会 `entry(peer).or_default()` 并 `touch()` session（`crates/daemon/src/backup.rs`），Android `BackupRunner.existCheck` 明确复用该旧批次校准路径，二者均不符合独立、只读的 P1 对账语义。
- 2026-09-01：daemon RED：`backup_flow` presence 合同因 `BackupPresenceQuery` 未定义而失败。GREEN：新增 `backup.presence` / `BackupPresenceQuery`、只读 `BackupEngine::presence()` 和 router 分派；目标集成测试 1/1 通过，已确认已提交 hash 不返回 missing、缺失 hash 原序返回，asset count 与 watermark 保持不变。Android adapter、空页/超页/非法 hash 反证仍待本卡后续完成。
- 2026-09-01：远端复核：CI Rust #70 与 Dogfood Binaries #203 均绿色。Android RED→GREEN：`ARCH01RemotePresenceProbeTest` 先因页面构造器缺失失败，后以 2/2 验证 500 项上限、输入顺序、空页/501 项/非法 hash 拒绝；实际 `DaemonClient` 调用与 missing 解码仍待接线。
- 2026-09-01：Android adapter 已接线为 `RemotePresenceProbe.missing()`：调用 `DaemonClient.call(..., backup.presence, ...)` 并解码 `BackupMissing`，不引用旧批次校准。`just ci` 全绿；本次 Android XML 53 files / 379 tests / 0 failures / 0 errors / 4 skipped。剩余只验证“若误委托给 manifest 会失败”的反证。
- 2026-09-01：反证实际执行：临时将 router 的 `backup.presence` 处理改委托 `backup.manifest`，presence 集成测试因错误创建 session 而失败（实际 `left: 1`, expected `0`）；还原后定向 Rust 测试与 `just ci` 全绿。
- 2026-09-01：远端 CI 复核：GitHub CI Rust #71 与 Dogfood Binaries #204（commit `9d5337e`）均成功。

## 备注

`backup.presence` 是业务事实查询，不是第二条传输协议：它复用既有 ctrl plane、配对鉴权和 `BackupMissing` 响应形状，只移除 manifest 的会话副作用。500 项是 ARCH-01 已定的发现/上传窗口容量；对账 caller 以同一上界分页，但页游标不在本卡定义。
