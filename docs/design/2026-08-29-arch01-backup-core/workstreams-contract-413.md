# #413 重构：工作流分工与接口契约

设计以同目录的 `final-design-413.md` 为准。本文件只定**谁改哪些文件**和**模块之间的接口**，各 agent 按契约独立开发，最后在集成分支 `feat/413-per-item-loop` 本地统一验证。

## 0. 通用规则（所有 agent）
- 每人只在自己的 worktree、自己的 wip 分支上改；**只改自己拥有的文件**。需要改别人拥有的文件时，停下来在报告里写明，不要改。
- 完成一个可编译、自己模块测试通过的里程碑，就 `git fetch origin && git rebase origin/feat/413-per-item-loop`，再 `git push origin HEAD:feat/413-per-item-loop`。push 被拒就再 rebase；**禁止 force push**、禁止 `--no-verify`、禁止放宽任何供应链门禁（`minimumReleaseAge`、cargo deny 等），不新增第三方依赖。
- commit message 用中文，末尾加一行：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 绝对不要写 `/Users/zhaowenli/personal/P-Pass` 主仓工作区（其他会话在用），只能从那里只读复制 gitignored 文件。
- 测试设备（本地桌面、模拟器 `ppass_api35`、三星 S9210）上都是测试数据，**可以清库重来，不需要兼容历史数据**：数据库 schema 直接升版本并重建，不写数据迁移。但不要删除设备上的用户照片；测试文件用 `ppexp_` 前缀。
- 用户可见文案：优先复用现有 strings；必须新增的，写成草稿并在报告里逐条列出（key、中文、英文、出现位置），标“待用户确认”。
- 代码注释密度、命名、风格与周围代码一致。

## 1. 文件归属
| 工作流 | 拥有的文件 |
|---|---|
| W1 Android 核心 | `apps/android/.../backup/flow/` 下除 W3、W5 列出的全部文件（FlowCore.kt、FlowEngine.kt、AndroidFlowRuntime.kt、NativeFlowDeliveryPort.kt、FlowControlStore.kt、FlowTransferForegroundService.kt、FlowWriter.kt、RemotePresenceProbe.kt 等）；`backup/order/` 全部；`transport/DaemonClient.kt`；`proto/Proto.kt`；BootWatchReceiver、MediaWatchJob、PPassApplication 里与触发相关的部分；对应单测 |
| W3 Rust 传输 + JNI | `crates/transport/`（含 `android_blobs.rs`）；`backup/flow/IrohBlobsProviderBridge.kt`、`backup/flow/AndroidNativeIrohBlobsProvider.kt`；新增 `backup/flow/AndroidMediaImporter.kt` |
| W4 桌面 | `crates/daemon/`、`crates/proto/`、`crates/storage/`（如需）、`apps/desktop/`（Tauri/前端的低空间通知） |
| W5 Android UI | `backup/BackupUiStateHolder.kt`、`backup/flow/FlowUiProjection.kt`、`backup/flow/LoopStatusRefresh.kt`、MainActivity 及 Compose/布局、`res/values*/strings.xml`、非 FGS 的通知 |
| W6 文档 | `docs/`（设计文档改名：发现 / 对账 / 传输，写入最终设计与本契约） |

`backup/flow/FlowContract.kt` 由主会话预先提交，是共享类型；W1 可以在其中补充，但不得改已有签名。

## 2. 共享类型（`FlowContract.kt`，已提交）
- `GlobalState { IDLE, RUNNING, PAUSED, WAITING }`
- `DesktopHealth(freeBytes: Long?, libraryWritable, indexOk)`，`lowSpace` = freeBytes < 5 GiB
- `PeerFailureKind { STORAGE_FULL, LIBRARY_UNAVAILABLE, STORAGE_ERROR }`
- `EngineView(state, waitReason, pending, doneThisRound, current, desktopHealth)`：UI 与 FGS 通知读的唯一视图
- `MediaImporter`（W3 实现，W1 调用）：`import(mediaId, contentUri, dataPath) → ImportResult`、`serve(lease) → ticket`、`release(contentHash)`

## 3. W1 ↔ W5
- W1 在 `FlowCore.kt` 的 `WaitReason` 中改成且只改成这些值：`NOT_PAIRED, DISABLED, WIFI, BATTERY, FGS_BLOCKED, DESKTOP_UNREACHABLE, DESKTOP_STORAGE_FULL, DESKTOP_LIBRARY_UNAVAILABLE, DESKTOP_STORAGE_ERROR`（删掉 `PEER_REFUSED`）。等待原因要持久化，进程重启后还在。
- W1 对外暴露 `StateFlow<EngineView>`（从 `AndroidFlowRuntime` 取），以及用户操作：`pause()`（只在 RUNNING 有效）、`resume()`（只在 PAUSED 有效）、`cancelRemaining(snapshot)`（在 PAUSED 与 WAITING 有效；清除暂停标志 → IDLE）、`restoreSkipped()`、`remainingSnapshot()`（弹窗那一刻的边界 + 张数）。
- W5 只读 `EngineView` 渲染；“继续”按钮只看 `state == PAUSED`；“取消剩余 N 张”只在 PAUSED / WAITING 出现。

## 4. W1 ↔ W3
- W1 在准备这一步调用 `MediaImporter.import(...)` 拿 hash（删掉 Kotlin 侧 `ContentHasher` 的单独读文件），建 order 后调用 `serve(lease)` 拿 ticket 再 offer；桌面回复“已有”或放弃这一张时调用 `release(hash)`。
- W3 在 Rust 侧：引用导入（`add_path_with_opts` + `ImportMode::TryReference`，路径与 fd 双校验，不满足回退复制，回退读缓冲 1 MiB）；导入与供数拆成两步；`has()` 为 true 时不走引用；原文件被改 / 截断 / 删除时供数中止并通过现有状态回报。`dataPath` 为 null（API 29 或查不到）时直接走复制。

## 5. W1 ↔ W4（JSON 字段名固定）
- `hello` 回复新增 `"health": {"free_bytes": <i64|null>, "library_writable": <bool>, "index_ok": <bool>}`；旧桌面没有这个字段时手机视为健康。
- `FlowFetchRequest` 新增 `"size_bytes": <i64>`（0 = 未知）。桌面 offer 时按它预检剩余空间，放不下直接拒绝，错误 msgKey = `storage_full`。
- `flow.failed` 推送与 offer 拒绝的 code：`storage_full`（ENOSPC）/ `library_unavailable`（照片库文件夹不存在、不可写）/ `storage_failed`（索引库等其他写失败）/ `fetch_failed`（路径问题，维持现状）。原来的 `materialize_*` 按错误原因归入前三个之一。手机映射：前三个 → `PeerFailure(PeerFailureKind)`，`fetch_failed` → 路径失败，其他未知 → 单张失败。
- 暂停 / FGS 被收 / 断网：手机调已有的 `flow.suspend`（桌面保持 grant active、半截受保护）；丢弃半截调 `flow.cancel_tuple`。手机不再在循环取消时发 `flow.cancel`。
- 桌面：active grant 超过 3 天没有续传 → 标记取消并允许回收半截。
- 桌面：照片库所在卷剩余 < 5 GiB 时发桌面系统通知（文案草稿列给用户确认）。
