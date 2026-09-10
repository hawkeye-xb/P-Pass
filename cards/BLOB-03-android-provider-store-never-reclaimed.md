# BLOB-03 Android 发送端 iroh-blobs-provider 仓确认不回收

> 🟡 状态：待共享回归（当前会话已接手并完成只读检查）· 协同分支：`main`
> 级别：L2 · 阻塞：等待自然新增来源
> 当前节点：已确认运行中的修复版，但当前设备没有 Flow ledger 项或 provider data 文件，故没有可验证的自然新增来源；未写入媒体、未重置配对
> 下一步：下次正常新增照片完成 Flow 后，只读记录 receipt 前后 provider data blob 数；等待至少一个 60 秒 GC 周期，确认归零且 ledger 确认不倒退

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

- [x] 复用 `iroh-blobs` 原生周期 GC（与桌面 `flow-blobs` 同一机制，60 秒
      周期），而不是手删 store 文件或改造 blobs wire protocol。
- [x] provider 只保护正在持有 Flow lease 的来源 hash；导入期间也不得让 GC
      误删正在注册的 blob。暂停/取消/失败可丢弃该保护：手机原始 MediaStore
      文件仍是可重新导入的权威来源，Desktop 端 partial 仍按既有机制保留。
- [x] 只有 daemon 已完成 native fetch、materialize，并持久化匹配 tuple 的
      `FlowCompletionReceipt` 后，才撤销该 lease 的 provider handler/保护；
      该 receipt 是当前协议中唯一安全的成功回收边界。receipt 被验证拒绝或
      未到达时不得释放。
- [x] 自动化反证：当前 active lease 的 blob 在 GC 轮次中不得被删除；撤销后
      会被 GC 回收；中断后重新注册同一源仍可完成传输并复用 Desktop partial。
- [x] 三星真机升级迁移：原先 7 个已确认来源 blob 在修复版重启后一个 GC 周期
      内由 4,100,446 bytes / 7 文件变为 0 bytes / 0 文件，且 7 条 ledger
      `CONFIRMED` 保持不变。
- [ ] 下一张新增来源的普通 Flow 完成后，复核新 TempTag 路径也在 receipt 后
      一个 GC 周期内回收；该机会性回归不应靠伪造媒体或重置现有配对制造。

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

实现记录（2026-09-10）：根因不是「没接 GC」，而是导入走了
`AddProgress::with_tag()`（`add_path(...).await` / `add_stream(...).await.await`
都解析到它）——每次注册给 provider store 落一个**持久 named tag**，GC 永远
不回收。修复：`with_config` 接 `FsStore::load_with_opts` 打开 60s 周期 GC；
`register_path_async`/`register_file_async` 改用 `.temp_tag()`（ephemeral），
`ActiveProvider` 持有 `retained: Option<TempTag>`，`activate` 时写入、`revoke()`
掉 tag 时 release。新 `release_retention()` 只掉 lease 的 tag、不掉 handler/
endpoint，保住决策 5 的连接复连。Kotlin 侧成功边界在
`NativeFlowDeliveryPort.acceptReceipt` 里、`relayFlowCompletion` 四字段校验通过
之后、`onReceipt`（推进 strict head）之前调 `bridge.releaseRetention`。自动化
反证：Rust `android_provider` 5/5（active lease 多轮 GC 存活、release 后回收且
endpoint 保活可复用，以及旧 named tag 升级迁移回收）；Android JVM
`IrohBlobsProviderBridgeTest` 4/4、`REBUILD03FlowRunnerTest` 10/10。升级迁移
三星真机已通过；正常新增来源的机会性回归保留在卡头，不靠伪造媒体制造。

升级迁移实证（2026-09-10）：为避免“只防后续增长、旧副本永留”的假修复，provider
启动时清掉此专用 store 内旧版 `with_tag()` 留下的 named tags；新版本只创建
lease 生命周期内的 `TempTag`。Rust `android_provider` 用户实跑 **5/5**（含旧版
named tag → 新版 provider → GC 回收）。三星覆盖安装修复 APK、强制重启后，5 秒
快照仍为 7 文件 / 4,100,446 bytes；等待 70 秒后为 **0 文件 / 0 bytes**，索引
`blobs.db` 留 561,152 bytes 属空仓元数据，ledger 仍为 7 `CONFIRMED`。
