# REBUILD-01 Android iroh-blobs Provider Bridge（L2）

> 🟠 状态：进行中 · 协同分支：`rebuild/rebuild-01-iroh-blobs` · 前置：REBUILD-00
> 级别：L2 · 阻塞：无
> 当前节点：核实 Android binding 与 native bridge 可行接点 · 下一步：最小 provider 注册/撤销/停止 API 与 debug 编译

## 问题

Android 的 `computer.iroh:iroh:1.1.0` 只暴露 raw Endpoint/stream；没有 blobs provider/fetch/resume。新 Flow 无法让 Desktop 对手机发起原生 fetch，也无法实现 partial resume。

## 期望行为

提供 Android 可调用的 iroh-blobs bridge：将已确认 hash 的本地源注册为 provider，Desktop 可用原生协议 fetch/resume；Pause 能停止当前 fetch 而不销毁有效 partial。

## 验收标准

- [ ] Android bridge 暴露 provider 注册、撤销和当前 fetch 停止所需最小 API；不自定义 offset/chunk map/raw upload。
- [ ] 仅当前 pairing epoch + lease 的 item 可被 provider 暴露。
- [ ] 停止后 valid partial 仍由 blobs store 识别；恢复走同一 fetch。
- [ ] Android debug 编译通过；真实传输验收留 REBUILD-04。

## 范围

- 只准动：Android iroh binding/bridge、必要原生构建接线及其最小 Kotlin adapter。
- 不准动：旧 BackupRunner push、Worker 切换、UI、业务状态机。

## 阻塞与依赖

REBUILD-00。可与 REBUILD-02 并行。
