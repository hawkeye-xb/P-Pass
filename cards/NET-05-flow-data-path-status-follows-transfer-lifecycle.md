# NET-05 Flow 数据面路径状态随传输生命周期上报　级别 L2

> 🟡 状态：代码完成，待共享真机回归
> 级别：L2 · 阻塞：无
> Owner: Hermes · 分支：`work/net-05-flow-path` · Base: `6fc1748`
> 前置：NET-04 的连接缓存与 `path_of(provider, ALPN_BLOBS)` 已在 main；**不等待**其 Pause / Cancel / Retry 真机回归后才开始本卡。

## 问题

T-090/T-092 已把 `devices.list[].connection` 渲染为「已直连」或「经中继连接」，但其来源是某设备最近存活的任意连接（`latest_live(peer)`）。它不能证明正在备份的文件实际使用的是哪条数据面连接：Flow 控制 peer 与 blobs provider 的 NodeId 可以不同，ctrl 与 blobs 的 ALPN 也不同。

NET-04 已能按 `(provider, ALPN_BLOBS)` 读取 iroh 当前选中的路径；缺的是把这条事实在 Flow 的实际生命周期内传到 desktop。

## 本卡决定的第一阶段契约

`devices.list` 对每个已配对设备新增可选字段：

```text
flow_connection: null | "direct" | "relay" | "unknown"
```

- `null`：该设备当前没有正在运行的 Flow fetch；它不是「离线」的同义词。
- 非空：仅代表**当前 active Flow fetch 的 blobs 数据面**，绝不借用 ctrl/最近连接来猜。
- `direct` 包含 LAN 与公网打洞直连；`relay` 是 iroh 当前 selected path 经 relay；`unknown` 是 fetch 已进入连接阶段但 iroh 尚不可读，绝不猜成 direct。
- 该字段只驻留内存：daemon 重启、fetch 终止或解绑后必须回到 `null`，不写数据库、不进审计、不作为计费依据。

桌面设备行仅在 `flow_connection != null` 时优先展示：

```text
unknown → 正在连接/传输（路径尚未确认）
direct  → 正在直连传输
relay   → 正在经中继传输（内容加密，中继无法读取）
```

否则保留 PRES-01/T-092 的既有在线与通用连接展示；不改变 `connection` 字段既有语义。

## 生命周期节点（第一阶段）

1. `FLOW_FETCH` 经授权并进入实际 fetch：以 `(control peer, queue_sequence, lease_token)` 登记 `unknown`，发 `device.changed`。
2. `Blobs::fetch_from` 的 `connect_raw(provider, ALPN_BLOBS)` 成功并已进入 NET-04 cache：立即读取 `path_of(provider, ALPN_BLOBS)`，将 `direct/relay/unknown` 写回同一 active entry，发 `device.changed`，随后才让 iroh-blobs stream 继续。
3. 成功 receipt、fetch 错误、guard/cancel、或 `FLOW_CANCEL`：仅当 lease 与当前 entry 相同才清为 `null` 并发 `device.changed`；旧请求不得清掉同设备的新请求。
4. 本阶段不承诺传输途中 iroh 自动 direct↔relay 切换的逐瞬时刷新；它明确是后续精准阶段。此阶段承诺的是「进入数据面连接后的真实快照」，而非从 ctrl 或心跳推测。

## 范围

- `crates/transport/src/blobs.rs`：在连接成功后把当前 data-plane 路径交给调用方，不能在 transport 外暴露 iroh 类型。
- `crates/daemon/src/flow_delivery.rs`：以 lease 防旧请求覆盖的内存状态表，负责节点 1–3。
- `crates/daemon/src/ipc.rs`、`main.rs`：`devices.list[].flow_connection` 与 `device.changed` 接线。
- `apps/desktop/src/lib/connection.js`、`App.svelte`：仅在 active Flow 状态时渲染对应人话。
- 相关 Rust/JVM/桌面纯函数测试。

## 不准动

- iroh 自身的 direct/relay 切换、NAT 穿透或 relay 策略。
- `devices.list[].connection`、PRES-01 三档在线语义、last_seen 口径。
- relay 服务端计费、审计、数据库 schema，或任何 Android Flow 严格消费者语义。
- 以定时轮询/猜测冒充精确路径更新。

## 可执行验收

- [x] RED：同一控制 peer 的旧 lease 终止不得清掉新 lease 的 `flow_connection`；修正 lease 守卫前测试失败。
- [x] transport：同一 provider 的 blobs 连接建立后，回调值来自 `path_of(provider, ALPN_BLOBS)`；不同 ALPN 不混用。
- [x] daemon：进入 fetch 先 `unknown`，连接就绪后更新为 transport 事实，成功/错误/cancel 清回 `null`；每次有效变化各发一次 `device.changed`。
- [x] IPC：`devices.list` 同时保留既有 `connection` 和新的 `flow_connection`，缺活跃 fetch 时后者为 JSON null。
- [x] desktop：Flow 状态文案/颜色纯函数测试覆盖 null、unknown、direct、relay，且 null 回退到既有 presence 文案。
- [x] `cargo test -p transport`、`cargo test -p daemon --test flow_delivery`、相关 desktop tests/build、`just queue-check` 通过（本地 `just ci` 全绿）。
- [ ] 真机验收另列于共享回归：慢速/大文件传输时，设备行先显示「正在连接/传输」，随后显示真实直连或中继；暂停/取消/失败后不残留「正在…」。

## 后续精准阶段（不在本卡）

若产品要宣称“实时当前路径”，需基于 iroh 路径切换观察能力补独立卡：传输进行中 direct↔relay 的 selected path 改变应刷新 `flow_connection`。不得把本卡的连接就绪快照包装成该能力。

## 2026-09-11 真机观察（未作为验收通过）

用户在一次蜂窝网络与公司 Wi‑Fi 切换的传输中观察到设备灯先为黄、后为绿，传完后为绿；重开 App 触发的另一轮传输中也观察到黄灯。随后在 HarmonyOS 后台相册变更未触发、重开 App 才触发的另一轮中，也观察到传输期间黄、完成后绿。此记录与「active Flow 才显示 data-plane 状态」的目标相关，但没有 daemon 的 `(provider, ALPN_BLOBS)` 路径证据，不能据此断言黄=relay、绿=direct，亦不能勾选本卡真机验收。后续回归须同时采集真实 selected path 与 UI 状态。
