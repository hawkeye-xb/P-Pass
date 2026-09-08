# NET-04 传输层连接复用与路径追踪（核心改造，不含UI）　级别 L2

> 🟡 状态：代码完成，待真机验收
> 级别：**L2**（新协议/校验/架构类，需强 agent + 真机验证）· 阻塞：无
> Owner: Hermes · 协同分支：`work/net-04` · Base: `3ad6248`
> 当前节点：Android App 全局 Endpoint + daemon `(NodeId, ALPN)` `ConnectionCache` 已合入
> 下一步：真机连续传输 ≥5 文件，确认仅一次 NAT 打洞；回归暂停/取消/失败重试。
> ⚠️ 本卡只做 Rust daemon + Android 传输层改造，不碰任何 UI 组件。
> UI 展示是衍生卡 NET-05（本卡未开出前不建；本卡完成后再开，
> parents 挂本卡），不要在本卡里顺手加 UI 代码。

## 背景（2026-09-08 用户+验收人讨论定案，完整讨论见本次会话）

讨论链条：数据传输通道划分 → iroh direct/relay 自动切换能力确认 →
连接追踪现状排查 → 与 `P-Pass-buisness` 仓库 `BIZ-00`
（2026-09-07 定案的商业化设计）对齐 → 发现「每个文件传输都新建
Endpoint/Connection、零复用」这一更根本的问题 → 判定连接复用与路径
追踪应合并为同一份底层数据结构，一次改造。

## 已确认的设计前提（不必重新讨论，讨论过程见本次会话）

1. **iroh 自动处理 direct↔relay 切换与 multipath 升级**（官方文档
   `docs.iroh.computer/protocols/using-quic`：「NAT traversal, relay
   fallback, and multipath are all handled at the QUIC layer
   automatically」）——本卡**不需要**实现连接切换逻辑，只需要**观测**它。
2. **一个 iroh `Endpoint` 内，对同一 NodeId 的路径协商结果（打洞学到的
   可达地址、direct/relay 判定）是共享的**（官方文档
   `docs.iroh.computer/concepts/endpoints`：「a single endpoint
   instance... ensures all the connections made share the same
   [底层路径状态], while still remaining independent connections」）。
   但 **iroh 不会自动复用 `Connection` 对象**——每次 `connect()` 调用
   始终产生一个全新连接，哪怕对端和 ALPN 完全相同。连接对象复用要
   应用层自己做，这正是本卡的核心工作，**不需要改动 iroh 库本身**。
3. **计费的权威计量点在服务端（自建 relay），不是客户端上报**——
   `BIZ-00` §三：「配额在 relay 服务端执行，客户端验签只是 UX 提示」。
   本卡做的状态查询/连接复用**只影响性能与 UI 展示**，不作为计费依据，
   因此不需要防篡改设计。
4. **ctrl 通道与文件传输通道共享同一个 Endpoint**，路径协商按
   NodeId 做，不按连接/ALPN 单独打洞——ctrl 连接已确认 direct 时，
   同一对端新开的文件传输连接大概率复用同一路径。这是本卡「先做
   Endpoint 复用，立刻见效」这一步的理论依据。

## 现状缺口（已用代码核实，详见本次会话记录）

- ① `crates/transport/src/iroh_impl.rs:130` 的 `conns:
  HashMap<NodeId, Connection>` **按对端一个槽位**存储，不区分 ALPN，
  且**只写不读**（注释自称「Sole consumer: conn_info」）——从未被
  `connect()`/`connect_raw()` 用来判断「要不要复用现有连接」，纯粹是
  被动记录表。
- ② 真正做文件传输的 `crates/transport/src/blobs.rs:127` 的
  `fetch_from()`（`connect_raw`）**每次调用都新建一次连接**，
  daemon 侧 `crates/daemon/src/flow_delivery.rs:131`（`FlowDelivery::
  fetch`，Flow pipeline 的唯一生产传输路径）在循环里逐个文件调用它，
  即连续传输 N 个文件 = N 次独立握手 + N 次独立 NAT 打洞协商。
- ③ Android 侧 `NativeFlowDeliveryPort.start()` 每次传输**新建一个
  `DaemonClient()`（即新建一个 iroh `Endpoint`）**，比①②更严重——
  新 Endpoint 意味着连打洞学到的路径信息都不共享，每个文件都要从零
  开始路径协商。对照组：`MainActivity.kt:132` 的 `client = remember
  { DaemonClient() }` 是 App 全局唯一一个 Endpoint，ctrl 通道
  （`call()`/`subscribeTimeline()`）全部复用它——Flow delivery 没有
  照抄这个已验证正确的模式。
- ④ `docs/QUEUE.md`/`cards/` 未发现任何现有卡覆盖以上缺口。

## 目标

1. **连接复用**：同一 (NodeId, ALPN) 的传输，只要连接还活着就复用，
   不重新握手、不重新走 NAT 打洞协商。
2. **路径追踪**：追踪数据结构从「按 NodeId 一个槽位」改为「按
   (NodeId, ALPN) 索引」，且这份数据结构由 ①的连接缓存直接维护
   （复用同一份状态，不建两套）。业务层可在传输前后各查一次当前
   路径（direct/relay/lan），为后续 UI 展示和 relay 计费统计打基础。
3. Android 侧 Flow delivery 停止自建 Endpoint，复用 App 全局已有实例。

## 设计方案（已在本次会话中定稿，实施前无需重新设计）

```
daemon 侧（crates/transport 新增，业务代码不感知连接新建/复用细节）：

  ConnectionCache（按 (NodeId, ALPN) 索引）：
    get_or_connect(peer, alpn) -> Connection
        查缓存[(peer, alpn)]
        若存在且 close_reason().is_none()（还活着）→ 直接返回
        否则 → self.ep.connect(...) 新建 → 存入缓存 → 返回
    path_of(peer, alpn) -> Option<ConnInfo>
        查缓存里这一条连接当前的 direct/relay/lan（复用 conninfo.rs
        的 classify()，不新写分类逻辑）
    空闲回收：连接闲置超过 N 秒无新 stream 活动 → 主动 close
        （独立于任何单个 item 的生命周期，不是「传完就关」）

  业务调用点改法：
    blobs.rs::fetch_from(peer, hash):
        let conn = cache.get_or_connect(peer, ALPN_BLOBS)?;  // 原 connect_raw
        store.remote().fetch(conn, hash).await

  与 ARCH-03 严格消费者的边界（不冲突，只需明确一次）：
    StrictConsumer 管理的是 stream 级别的开始/取消（业务语义）；
    ConnectionCache 管理的是 connection 级别的建立/复用（传输层实现）。
    取消一个 item = 关闭/reset 这一条 stream，不触碰底层 connection；
    连接是否复用对严格消费者的行为不可见、不可影响。

Android 侧：
  NativeFlowDeliveryPort 不再 DaemonClient().also { it.bind(...) }；
  改为接收注入的、App 级别已存在的 DaemonClient（对齐
  MainActivity.kt:132 已验证的模式），与 ctrl 通道共享同一 Endpoint，
  立即免费获得 iroh 的路径协商结果共享。
```

**术语澄清（讨论中已确认，写在这里防止实施时理解偏差）**：
这不是传统意义的「连接池」（同一 key 维护多条连接供并发请求轮流借用）。
QUIC 原生支持一条连接上开多个并发 stream，不需要多条连接换并发，所以
这里是「按 key 缓存单条连接」（keyed connection cache / 近似单例），
池化的复杂度（借还、连接数上限管理）不需要。

## 分阶段（可分两次提交，但设计目标是下面这个终态，不要只做半步就停）

1. **第一步**：Android 侧 Flow delivery 改用 App 全局 Endpoint（对照
   `MainActivity.kt:132`）。改动小、立刻生效，免费拿到路径协商共享。
2. **第二步**：daemon 侧建 `ConnectionCache`，`blobs.rs::fetch_from`
   接入；路径追踪数据结构（缺口①②）随 `ConnectionCache` 一起落地，
   不再单独设计一套「只写不读」的记录表。

## 范围

- `crates/transport/src/iroh_impl.rs`：新增 `ConnectionCache`（或在
  现有 `conns` 字段基础上改造为「按 (NodeId, ALPN) 索引 + 真正被
  connect 路径读写」），移除「只写不读」的死数据。
- `crates/transport/src/blobs.rs`：`fetch_from()` 改为走
  `ConnectionCache::get_or_connect`。
- `crates/daemon/src/flow_delivery.rs`（`fetch()`）、
  `crates/daemon/src/backup.rs`（回退拉取路径）：确认改造后行为不变
  （幂等、断点续传等既有语义不受影响），补充针对连接复用的测试。
- Android `apps/android/.../backup/flow/NativeFlowDeliveryPort.kt`：
  改为接收注入的 `DaemonClient`，不再自建。
- Android `AndroidFlowRuntime.kt`（或 Flow runtime 装配点）：确认
  App 全局 `DaemonClient` 能正确传递到 Flow delivery 构造路径。

## 不准动

- iroh 底层连接建立/切换逻辑本身（不用户实现，属于 iroh 内部）。
- relay 服务端计量/计费逻辑（属于 `P-Pass-buisness` 私仓 `BIZ-01`/
  billing 服务范畴，排期在 H-07 relay 三区域部署之后，本卡不涉及）。
- `NET-01`（`backup.begin` 15 秒超时）的超时值调整——相关但独立，
  不在本卡范围。
- **任何 UI 组件**（`apps/desktop/src/lib/connection.js`、Android
  i18n 文案、devices.list 展示逻辑）——UI 接线是衍生卡 NET-05，
  本卡完成、验收通过后再开，不要在本卡里顺手做。
- `ARCH-03` 严格消费者内部语义、`StrictConsumer`/`FlowRunner` 状态机
  （连接复用对它们必须透明，出现耦合即视为设计错误）。

## 可执行验收

- 单测（daemon）：构造场景验证 `ConnectionCache.get_or_connect` 对
  同一 (peer, alpn) 连续调用两次，返回同一个 `Connection`（只要它还
  活着）；对不同 ALPN（如 ctrl vs blobs）返回不同连接，互不覆盖。
- 单测：连接被关闭（`close_reason().is_some()`）后再次
  `get_or_connect` 必须新建，不能返回死连接。
- 单测：路径查询结果按 (NodeId, ALPN) 区分——构造同一对端同时有
  ctrl 连接（模拟 direct）和文件传输连接（模拟 relay）的场景，断言
  两次查询返回不同结果（覆盖原 NET-04 的路径追踪目标）。
- 反证：把 `fetch_from` 改回每次新建 connect，上面「返回同一个
  Connection」的测试必须变红——证明测试真的在断言复用发生了，不是
  凑巧通过。
- 真机验收：连续传输多个文件（同一批次 ≥5 张），daemon debug 日志
  确认只有一次 NAT 打洞协商记录，后续文件复用已建立的连接/路径；
  单文件传输的暂停/取消/失败重试行为与改造前一致（ARCH-03 既有单测
  全绿 + 真机手动验证暂停/取消不受影响）。
- `just ci` 全绿；Android JVM 测试报告实际测试数（不是只看退出码 0）。

## 证据要求

报绿附命令 + 输出摘要；真机验收附实际日志（连接复用发生的证据）+
既有暂停/取消回归的手动验证记录。
