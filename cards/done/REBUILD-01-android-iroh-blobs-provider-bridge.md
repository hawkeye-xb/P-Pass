# REBUILD-01 Android iroh-blobs Provider Bridge（L2）

> ✅ 状态：已完成 · 协同分支：`rebuild/rebuild-01-iroh-blobs` · 前置：REBUILD-00
> 级别：L2 · 阻塞：无
> 当前节点：Android native blobs provider 已验证 · 下一步：REBUILD-03 接入新生产 Flow runner

## 问题

Android 的 `computer.iroh:iroh:1.1.0` 只暴露 raw Endpoint/stream；没有 blobs provider/fetch/resume。新 Flow 无法让 Desktop 对手机发起原生 fetch，也无法实现 partial resume。

## 期望行为

提供 Android 可调用的 iroh-blobs bridge：将已确认 hash 的本地源注册为 provider，Desktop 可用原生协议 fetch/resume；Pause 能停止当前 fetch 而不销毁有效 partial。

## 验收标准

- [x] Android bridge 暴露 provider 注册、撤销和当前 fetch 停止所需最小 API；不自定义 offset/chunk map/raw upload。
- [x] 仅当前 pairing epoch + lease 的 item 可被 provider 暴露。
- [x] 停止后 valid partial 仍由 blobs store 识别；恢复走同一 fetch。
- [x] Android debug 编译通过；真实传输验收留 REBUILD-04。

## 范围

- 只准动：Android iroh binding/bridge、必要原生构建接线及其最小 Kotlin adapter。
- 不准动：旧 BackupRunner push、Worker 切换、UI、业务状态机。

## 阻塞与依赖

REBUILD-00。已与 REBUILD-02 并行完成。

## 验收记录

- `crates/transport` 增加 Android `cdylib` JNI bridge，实际使用 `iroh-blobs`
  `FsStore`、`BlobsProtocol` 与标准 ticket；Kotlin adapter 校验 epoch、queue lease 与 token。
- provider revoke 会停止活动 fetch 并关闭 provider，但不清理接收端 partial；没有新增 raw upload、offset 或 chunk-map 协议。
- 验证：`cargo test -p transport --test android_provider` 1 passed；focused Android JUnit
  2 tests / 0 failures；`assembleDebug` 成功，APK 含 `libiroh_ffi.so` 与 `libtransport.so`。
