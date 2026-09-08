# NET-04：连接复用三星真机验收与排障记录（2026-09-08）

**关联卡**：[NET-04](../../cards/NET-04-connection-path-tracking-for-transfer-and-billing.md)  
**状态**：连续成功项的连接复用已由真机证明；Pause / Cancel / 失败 Retry 的真机回归仍待完成。  
**公开草稿**：[`site/src/content/blog/one-connection-was-not-one-connection.md`](../../site/src/content/blog/one-connection-was-not-one-connection.md)（`draft: true`，未发布）。

> 本文是工程取证与复现记录。省略设备序列号、NodeId、配对 token、本机路径、照片内容与原始完整日志；这些不是复现所需的事实，也不应进入仓库。

## 结论先行

第一次实机验收失败：5 个连续文件都成功备份，却出现 **5 个不同的数据面 provider NodeId**，因此 daemon 的 `(NodeId, ALPN)` `ConnectionCache` 必然每次 miss。

根因有两层：

1. Android native blobs provider 每次 `register` 都建立新 store、新 Endpoint、新 router；
2. Flow bridge 在相邻正常项之间也调用 `stopActiveFetch` + `revoke`，把上一项的数据面服务与连接一并砍掉。

修复后，native provider 在 provider 生命周期内保留同一 Endpoint、store 与 router；相邻已完成项只注册下一份内容，不再 revoke。显式 Pause / Cancel 仍会停止当前 active fetch 并撤销 provider，保持严格消费者的业务语义。

第二次实机验收：5 个新文件全部 `CONFIRMED`，`attemptCount=0`，每项都有 completion receipt；daemon debug 日志只见 **一次** `ppf/blobs/1` connection/hole-punch，后续五个 `iroh_blobs::get::fsm` 请求复用该连接。

## 设计不变量

| 不变量 | 含义 | 证据/边界 |
|---|---|---|
| daemon cache key 是 `(NodeId, ALPN)` | 同 peer、同协议的一条 QUIC `Connection` 承载多个 stream；不同 ALPN 不混用 | `ConnectionCache` integration test |
| Endpoint 与 Connection 不同 | iroh Endpoint 共享路径知识，但 `connect()` 不自动复用 Connection | card 的 iroh 文档前提 + transport test |
| control peer 与 data provider 可不同 | flow 控制 RPC 的身份不等于 blobs ticket provider 的身份 | 首轮日志中不同 provider NodeId 证明不能假设相同 |
| 普通相邻项不能销毁数据面 | 上一张完成后，下一张应开 stream，不应重建 Endpoint/Connection | `IrohBlobsProviderBridgeTest` + 二轮实机日志 |
| Pause / Cancel 仍必须中断 active fetch | 复用不得跨越用户显式停止；partial 与严格队头既有语义不变 | 仍待真机回归 |

## 真机验收步骤

### 0. 工件和运行态先验

目标不是“源代码能编译”，而是确认运行中的双端确实来自待测代码：

1. 从当前 `main` 构建 daemon 与 Android debug APK；
2. 停止旧 daemon，启动刚构建的 daemon，并开启 `transport=debug,iroh=debug`；
3. `adb install -r` 覆盖安装 APK，随后 force-stop 再启动 App；
4. 用包管理器读取安装时间，并确认手机 App 进程和 daemon 进程都存活；
5. 读取最小的非敏感 Flow 聚合（已选相册、ledger 项状态计数），确认有资格运行测试。

**为什么要这样做**：本轮第一次部署前，桌面调试壳会自动拉起旧 sidecar；若没有先停掉它，手机装新 APK 也只是在对旧 daemon 做回归，结论无效。

### 1. 构造隔离测试输入

在已选择的 Screenshots 相册写入 5 张明确命名为 `NET04-test-e-*` 的小型 PNG，然后让 MediaStore 完成扫描。

约束：

- 不使用真实用户照片；
- 五份内容不同，避免 dedup 把“未传输”伪装成成功；
- 测试名只用于本机识别，本文不记录文件名以外的媒体信息；
- 这些测试图没有被自动删除，避免破坏可追溯证据。清理由所有者决定。

### 2. 读取结果，而不是只看退出码

读取手机侧 ledger 中该批测试项的聚合：

```text
5 项发现
5 项 CONFIRMED
attemptCount 均为 0
5 个 completion receipt
```

这证明 Desktop 已完成 data fetch、持久化并回执；不是只证明“App 看起来没有报错”。

### 3. 从 daemon 日志验证连接形状

**失败轮（修复前）**：每个文件的 `ppf/blobs/1` connection 对应不同远端 provider identity。即使 daemon cache 本身正确，key 变化也使复用不可能发生。

**成功轮（修复后）**：

```text
一次 ppf/blobs/1 connection / hole-punch
随后 5 次 iroh_blobs::get::fsm 请求
无第二次 blobs connection
```

这才是“连续 5 项复用同一数据面连接”的证据。

## 代码与测试映射

| 层 | 文件 | 改动/判据 |
|---|---|---|
| daemon | `crates/transport/src/iroh_impl.rs` | `ConnectionCache` 按 `(NodeId, ALPN)` 缓存，连接关闭观察和空闲回收；`path_of` 读取同一份状态 |
| daemon fetch | `crates/transport/src/blobs.rs` | `fetch_from` 经 `connect_raw` / cache 使用 connection 开 stream |
| Android control | `PPassApplication.kt`、`AndroidFlowRuntime.kt`、`NativeFlowDeliveryPort.kt` | Flow delivery 注入 App 级 `DaemonClient`，不再临时创建 control Endpoint |
| Android data | `crates/transport/src/android_blobs.rs` | provider 生命周期内单 Endpoint/store/router；动态 handler 仅在 revoke 后切换 |
| Android bridge | `IrohBlobsProviderBridge.kt` | 正常相邻严格项不 revoke；Pause / Cancel 保留 stop + revoke |
| local counterfactual | `crates/transport/tests/loopback.rs` | 同 key 复用、不同 ALPN 隔离；恢复每次 connect 即失败 |
| provider regression | `crates/transport/tests/android_provider.rs` | 连续注册两项保持同一 provider identity，并经 `fetch_from` 传两项 |
| bridge regression | `IrohBlobsProviderBridgeTest.kt` | 相邻已完成项不会产生 stop/revoke；Pause 仍会产生 stop/revoke |

## 已跑验证

- `cargo test -p transport`
- `cargo test -p daemon --test flow_delivery`
- Android JVM 全量测试（机器可解析报告：308 tests / 0 failures / 0 errors / 4 skipped）
- `just ci`（fmt、clippy、nextest/test、architecture、queue check 全绿）
- GitHub CI Rust 和 CI Android 均在修复提交上成功

## 未完成的真机项

不要把本记录的成功外推成暂停/取消已经通过。下列项仍待一次**带真实 active head**的完整真机回归：

1. 大于瞬时完成时间的单文件传输中点击 Pause：当前 stream 停止、partial 保留、账本保持可恢复；
2. Continue：原严格队头恢复，不能跳过或并行启动下一项；
3. Cancel 当前轮：当前项和同轮未完成项进入既定取消语义，已 `CONFIRMED` 项不倒退；
4. 人为断开 daemon 后 Retry：错误显性化、重连后按既有失败预算/严格队头继续；
5. 上述每步后再检查没有普通相邻项的“隐式 revoke”回归。

## 下次排障最短路径

若以后又出现“文件传成功，但连接仍不断重建”：

1. 先看数据面 ticket provider identity 是否稳定；不要先怀疑 daemon cache；
2. 再看任何 item 边界是否调用了 endpoint/router/provider 的 close、shutdown 或 revoke；
3. 检查日志中 `ppf/blobs/1` connection 数和 `get::fsm` 请求数是否是一对多；
4. 最后才看 direct / relay 路径质量。路径质量不能解释 provider NodeId 每项变化。

这条顺序能避免把一个生命周期 bug 误诊成 NAT、relay 或计费问题。
