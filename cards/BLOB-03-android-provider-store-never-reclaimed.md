# BLOB-03 Android 发送端 iroh-blobs-provider 仓可能永不回收（待排查）

> ⬜ 状态：未开工
> 级别：L2 · 阻塞：无

## 问题

2026-09-10 BLOB-01/BLOB-02 真机回归准备阶段，核实 GC 触发机制时顺带发现：
Android 手机作为发送方时，通过 `AndroidBlobsProvider::register_path`
（`crates/transport/src/android_blobs.rs:206`）把要发送的文件导入一个
独立的 iroh-blobs store（目录 `<root>/iroh-blobs-provider`），供桌面端
拉取。

源码核实（`iroh-blobs` 0.103.0 vendored 源码 `src/api/blobs.rs:265-270`）：
`add_path` 默认 `ImportMode::Copy`——每次导入会在手机本地**真实拷贝一份**
文件到这个 provider store，不是引用/硬链接。

全仓搜索 `android_blobs.rs` 及其消费者（`AndroidNativeIrohBlobsProvider.kt`）：
`stop_active_fetch()` / `revoke()` / `close()` 都只处理网络连接层面的
断开/停止接受，**没有任何一处删除 store 里已导入的文件**。这个 store
本身也没有像桌面 `flow-blobs` 那样接入 `open_with_periodic_gc`。

对照 BLOB-01/BLOB-02 的问题模型：这与桌面端"ingest 后 blob 不回收"、
"flow-blobs 从不回收"是同一类缺陷（导入产生副本，副本无回收路径），
只是发生在手机发送端而非桌面接收端。

## 需要先排查清楚，再决定是否要修

- [ ] 确认这个 provider store 目录在真机上的实际路径（Android 沙盒内，
      大概率是 app 私有存储 `filesDir` 下）
- [ ] 确认导入行为：是否每次发送握手都调用一次 `register_path`（即每
      发一张照片占盘涨一份），还是同一个文件多次发送会被去重
- [ ] 用 `adb shell run-as com.hawkeyexb.ppass du -sh <provider目录>`
      连续发送一批照片前后实测占盘变化，拿到真实数据再判断严重程度
      （不要凭代码推测就下结论——可能存在这里没查到的清理时机，比如
      `provider.close()` 在某个生命周期节点被调用并清空整个 store）
- [ ] 若确认会无限增长：参照 BLOB-01（ingest 后即时删除）或 BLOB-02
      （接入周期 GC）两种模式，评估哪种更适合手机侧发送场景——手机作为
      发送方，"何时可以安全删除已发送的这份 provider 副本"的判据需要
      重新设计（不能照抄桌面端 `flow_delivery.state`，因为这是反方向：
      手机不知道桌面是否已经完整收到并确认）

## 范围

- 只准动：`crates/transport/src/android_blobs.rs`、
  `apps/android/.../backup/flow/AndroidNativeIrohBlobsProvider.kt`
  及其调用方、对应测试。
- 不准动：桌面端 `.ppf/blobs`、`.ppf/flow-blobs`（BLOB-01/BLOB-02 范围，
  与本卡无关）；Flow 协议/状态机语义。

## 阻塞与依赖

无。本卡是排查任务，排查结论可能是"确认有泄漏，需要修"或"实际有清理
机制，误报关闭"，两种结论都需要在实施记录里写清楚源码依据。

---

## 备注

发现路径：2026-09-10 讨论 BLOB-02（flow-blobs GC 60 秒轮询）触发机制时，
用户追问桌面端之外是否还有类似风险，顺藤查到手机发送端这个独立 store。
未做真机验证，纯代码走读发现，需要本卡完整走一遍排查步骤后才能定性。
