# MOB-62 断开后重扫必须清空旧 Flow 运行态（L2）

> 🟡 状态：代码完成，待三星真机验收；先前的旧 Flow 清理已合并，但同场景仍触发主线程 ANR，需修复后重新真机验收
> 级别：L2 · 阻塞：无

## 问题

手机主动断开后重新扫码同一台电脑，必须是全新业务会话。现有 `clearLocalPairing()` 只删 pairing/confirmed cache、取消一个 periodic work；它遗留 `flow-state/<NodeId>`、内存 `flowRuntimes` 和 catchup/manual/process/media-watch wakes。真机表现为旧 offer 连续发起、主线程 ANR、重连后崩溃。

## 期望行为

断开提交后旧会话的所有本地 Flow 状态与调度都不可再运行；重扫同一 NodeId 后只创建新 runtime/new ledger。不得触碰照片库。

## 验收标准

- [ ] 断开后所有 unique Flow wake work 与 media watch 均取消；旧 runtime/provider 关闭并从 map 移除，旧 remote Flow ledger 删除。
- [ ] 重扫同一 NodeId 后首次 wake 只读新 runtime/new ledger；无旧 offer、无 ANR/崩溃；状态读取不得在主线程创建 native runtime。
- [ ] JVM 覆盖 reset 语义；Android build/test 与 `just ci` 通过。
- [x] 三星真机（2026-09-09）：桌面移除+手机主动断开→重新扫码→允许连接→
      进入首页，全程不崩溃；随后选择相册开始新一轮备份，正常传输。

## 范围

- 只准动：Android pairing cleanup、Flow runtime 生命周期、`BackupUiStateHolder` 的状态读取/初始化边界、work/media-watch cancel 与测试、卡/队列/进度。
- 不准动：daemon pairing auth、照片库/用户媒体、传输协议。

## 阻塞与依赖

无。

---

## 实施记录

- 2026-09-11：已认领。DropBox trace 已把根因收敛到 UI 轮询经 `flowLedgerSnapshot()` 懒创建 native runtime；先以快照只读合同写 RED，再把 runtime 创建移出 UI 线程。
- 2026-09-11：RED：`MOB62SnapshotReadOnlyTest` 证明快照路径调用 `runtimeFor()`。GREEN：快照只读同 epoch 的现有 runtime ledger；没有 runtime 时直接读取 `flow-state/<nodeId>`，不初始化 native provider。focused JVM、Android JVM 343/0/0/4（68 XML）、debug APK 与 `just ci` 全绿。待三星重扫同机验证无 ANR/旧 offer、并完成新轮传输。
- 2026-09-08 三星系统记录 `MainActivity` ANR；logcat 同时可见旧 `flow.fetch` offer 密集重放。
- 2026-09-08 Samsung SM-S9210 真机回归：从当前 `main` 重建、覆盖安装 debug APK 后，手机主动断开 → 手动输入新的单次配对串 → 桌面 daemon 检出 pending 后立即允许；手机稳定进入「选择要备份的相册」，没有 ANR、崩溃或旧 offer UI。未点「开始备份」，避免向真实照片库发起传输；"进入首页后开始一轮新备份"仍待单独验收。
- 2026-09-09 Samsung SM-S9210 组合回归：桌面移除设备 + 手机主动断开 → 重新扫码 → 允许连接 → 选相册 → 开始一轮新备份，全程无崩溃/ANR/旧 offer，正常传输完成。余项已闭环。
- 2026-09-11 回归：同一业务场景再次出现 Android ANR。系统 DropBox trace 显示主线程的 500ms `BackupUiStateHolder.refreshFlowState()` 经 `flowLedgerSnapshot()` 进入 `runtimeFor()`，在持有 `flowRuntimeLock` 时首次调用 `AndroidNativeIrohBlobsProvider.open()` / `nativeOpen()`；native 初始化阻塞超过 ANR 门限。此前清旧 runtime/ledger/wake 的修复仍在，但它没有禁止 UI 状态读取懒创建 runtime，故本卡重新打开。下一步：先写「状态快照不创建 native runtime / 初始化只能在 IO」失败用例，再修生产边界。