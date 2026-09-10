# BLOB-03 Android 发送端 iroh-blobs-provider 仓确认不回收

> 🟡 状态：进行中 · 协同分支：`main`
> 级别：L2 · 阻塞：无
> 当前节点：三星真机从卸载后的空 App 数据开始同步 7 张，7 个均 `CONFIRMED` 后 provider 仍留 7 个数据文件（4,100,446 bytes）和索引（561,152 bytes）
> 下一步：在不改变 Flow 协议/状态机的前提下，接入 iroh 原生周期 GC，并只保护当前 lease 的来源 blob；持久 completion receipt 后撤销保护

## 问题

2026-09-10 BLOB-01/BLOB-02 真机回归准备阶段，核实 GC 触发机制时顺带发现：
Android 手机作为发送方时，通过 `AndroidBlobsProvider::register_path`
（`crates/transport/src/android_blobs.rs:206`）把要发送的文件导入一个
独立的 iroh-blobs store（目录 `<root>/iroh-blobs-provider`），供桌面端
拉取。

源码核实（`iroh-blobs` 0.103.0 vendored 源码 `src/api/blobs.rs:265-270`）：
`add_path` 默认 `ImportMode::Copy`——每次导入会在手机本地**真实拷贝一份**
文件到这个 provider store，不是引用/硬链接。

真机已复现：卸载后重新安装，确认 App 私有 `files` 目录尚未创建；完成 7 张
Flow 同步后，ledger 为 7 个不同 hash、7 个 `CONFIRMED`，provider store 同时留下
7 个 data 文件。来源副本的已知大小为 4,100,446 bytes，`blobs.db` 为 561,152
bytes。因而这不是纯代码推测：成功 receipt 后的手机副本确实未回收。

全仓搜索 `android_blobs.rs` 及其消费者（`AndroidNativeIrohBlobsProvider.kt`）：
`stop_active_fetch()` / `revoke()` / `close()` 都只处理网络连接层面的
断开/停止接受，**没有任何一处删除 store 里已导入的文件**。这个 store
本身也没有像桌面 `flow-blobs` 那样接入 `open_with_periodic_gc`。

对照 BLOB-01/BLOB-02 的问题模型：这与桌面端"ingest 后 blob 不回收"、
"flow-blobs 从不回收"是同一类缺陷（导入产生副本，副本无回收路径），
只是发生在手机发送端而非桌面接收端。

## 修复目标与验收标准

- [ ] 复用 `iroh-blobs` 原生周期 GC（与桌面 `flow-blobs` 同一机制，60 秒
      周期），而不是手删 store 文件或改造 blobs wire protocol。
- [ ] provider 只保护正在持有 Flow lease 的来源 hash；导入期间也不得让 GC
      误删正在注册的 blob。暂停/取消/失败可丢弃该保护：手机原始 MediaStore
      文件仍是可重新导入的权威来源，Desktop 端 partial 仍按既有机制保留。
- [ ] 只有 daemon 已完成 native fetch、materialize，并持久化匹配 tuple 的
      `FlowCompletionReceipt` 后，才撤销该 lease 的 provider handler/保护；
      该 receipt 是当前协议中唯一安全的成功回收边界。receipt 被验证拒绝或
      未到达时不得释放。
- [ ] 自动化反证：当前 active lease 的 blob 在 GC 轮次中不得被删除；撤销后
      会被 GC 回收；中断后重新注册同一源仍可完成传输并复用 Desktop partial。
- [ ] 三星真机：从干净安装完成一批确认同步，等待至少一个 GC 周期后 provider
      store 不再保留已确认来源 blob；同步、Pause/Continue 均未回归。

## 范围

- 只准动：`crates/transport/src/android_blobs.rs`、
  `crates/transport/tests/android_provider.rs`、
  `apps/android/.../backup/flow/AndroidNativeIrohBlobsProvider.kt`、
  `IrohBlobsProviderBridge.kt`、`NativeFlowDeliveryPort.kt` 及对应测试。
- 不准动：桌面端 `.ppf/blobs`、`.ppf/flow-blobs`（BLOB-01/BLOB-02 范围，
  与本卡无关）；Flow 协议/状态机语义。

## 阻塞与依赖

无。真机定性已完成；本卡现为修复任务。

---

## 备注

发现路径：2026-09-10 讨论 BLOB-02（flow-blobs GC 60 秒轮询）触发机制时，
用户追问桌面端之外是否还有类似风险，顺藤查到手机发送端这个独立 store。
2026-09-10 已完成三星真机定性，见「问题」与「修复目标与验收标准」。
