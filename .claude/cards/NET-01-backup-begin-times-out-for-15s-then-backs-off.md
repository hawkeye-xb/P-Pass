# NET-01 半小时内三次传输层失败——`backup.begin` 卡满 15 秒才超时　级别 L2

> 🔴 状态：待调查（先定性，再决定修不修）
> 级别：**L2** · 阻塞：无

## 现象

2026-08-26 真机回归（0.4.0-test.8）半小时内三次：

```
17:04:33  DaemonUnreachableException: backup.begin: no response from the computer within 15000ms
17:16:48  IrohError { kind: Stream, message: "ConnectionLost(TimedOut)" }
17:23:40  DaemonUnreachableException: backup.begin: no response from the computer within 15000ms
```

验收人反馈的回归步骤 #18 大概率就是这个：

> 「重新打开 app，设置里面有提示，并且同步开始计算图片，**计算后等待较长时间
> 才发起重传**。」

**不是计算慢**——是 `backup.begin` 把 15 秒超时耗满，然后按 `MOB-02 §五` 的
30 秒指数退避重排。用户看到的就是「算完了，然后干等」。

## 要查清的（按顺序）

1. 这三次失败时 daemon 侧发生了什么？两端时间线对齐（daemon 日志在
   `~/Pictures/P-Pass 家庭照片库/` 的 `.log`/`.err`）。
2. `ConnectionLost(TimedOut)` 是 iroh 的连接空闲超时，还是真的网络断了？
   17:16:48 那次是**传到一半**断的（`sending 54/198` 之后），与另两次
   （`backup.begin` 阶段就打不通）可能不是同一个病。
3. 15000ms 这个超时值是否过长？握手阶段打不通，等 15 秒对用户是纯损失；
   但传输中的流不该被短超时砍断——两者可能需要不同的超时。

## 与已知项的关系

- 这三次都发生在**已授权白名单之后**，所以不是 `DOG-03` 的冻结问题。
- `UX-14` 修的是「失败被显示成被暂停」这个**呈现**缺陷；本卡查的是失败
  本身为什么发生。两张卡不重叠。

---

# 2026-08-27：根因链闭合,建议提级 **L0**

## 决定性的新证据

家中 agent 拿到了 `devices.list` 里那个字段（前两轮报告都只报了
`presence`，漏了它）：

```
ALN-AL00  connection = "relay"
```

**手机走的是中继,不是直连。打洞没成功。**

## 完整因果链

`apps/android/.../transport/DaemonClient.kt:42`：

```kotlin
private const val CONNECT_TIMEOUT_MS = 15_000L
```

这个 15 秒**同时管两件事**：

| 位置 | 管什么 | 超时错误串 |
|---|---|---|
| `:54` `connectBounded` | **建立连接** | `could not reach the computer within 15000ms` |
| `:116-141` | 单次 RPC 等响应 | `<method>: no response from the computer within 15000ms` |

链条：

```
5G / 跨网络 → 打洞失败 → 连接落到 relay 上（connection="relay" 实证）
        ↓
relay 路径下建连接慢（n0 公共 relay，代码注释自己写着 rate-limited）
        ↓
15 秒超时 → DaemonUnreachableException
        ↓
backup.begin 请求从未送达 → **daemon 侧零 backup.started**（audit 实证）
        ↓
Result.retry() → WorkManager 退避（30s 起，指数增长）
        ↓
手机界面：ENQUEUED 既不是 finished 也不是 running → 显示 Idle/AllSafe（UX-15）
        ↓
英雄区按钮因此不渲染，而设置页那个入口不存在（MOB-43）
        ↓
    用户：连上了、状态正常、就是不传、无处可点、只能杀进程
```

## 这条链解释了此前所有零散观察

| 观察 | 解释 |
|---|---|
| 8/26 22:29–22:36 传成 13 张 | 那时**在家里同一网段**——LAN 直连，不走 relay |
| 22:36 之后不传 | 离家 / 网络路径变化后落到 relay |
| 8/27 全天零 `backup.started` | connect 阶段就 15 秒超时，请求从未送达 |
| 手机能预览大图 | 预览走**已建立的 ctrl 连接**（`DaemonClient.kt:173`），小数据、单张，不需要在 relay 上新建连接 |
| 界面「状态正常」 | UX-15：retry 中的 work 在状态机里没有位置 |
| 验收人「打洞成功了但数据不一定能传」 | **方向对了**，只是比他说的更靠前——打洞压根没成功 |

## 「这是鸿蒙的问题」——不是

验收人 2026-08-27 判断「现在只存在问题，就是在鸿蒙 5G 手机上」。

**与鸿蒙无关。** 换任何一台手机、只要连接落到 relay 上，都会撞上这同一个
15 秒。此前三星真机回归全部在**同一网段或办公网**做的（LAN 直连），所以从
没撞上——除了 8/26 test.8 那三次，而那三次就是本卡的原始现象。

判据：`connection` 字段。`direct` → 不会撞；`relay` → 会撞。

## 为什么建议 L0

它不是"某些网络下慢"，它是**跨网络场景下备份功能整体不可用**，而且叠加
UX-15 + MOB-43 之后用户**没有任何出路**。而"在外面用手机备份照片"正是这个
产品的核心场景之一。

## 待验证（这条链仍是假设，只是最强的那个）

**要看的一行**：debug 级 daemon 日志里有没有手机的 inbound 连接尝试。

- **有 inbound、无 `backup.started`** → 连接建到一半死了或 RPC 超时
- **连 inbound 都没有** → connect 在手机侧就超时了，压根没碰到 daemon
  （本卡假设的形状）

判决实验的完整指令在
`docs/evidence/2026-08-26-home-partial-upload.md`（v2 版）。⚠️ 8/27 那次实验
**没跑成**——家中 agent 为开 debug 重启了 daemon，用户那次"杀 App 重开"正好
落在重启竞赛期，手机连的是被杀掉的旧实例。要重跑。

## 修的方向（先不动手，等验收人拍板）

三件事，独立可做：

1. **connect 超时与 RPC 超时分开。** 建连接在 relay 路径下天生慢，15 秒是按
   LAN 直觉定的数。分开之后 connect 可以给 60s 而 RPC 保持 15s。
2. **超时要说出来。** `DaemonUnreachableException` 现在被 `catch (t: Throwable)`
   吞进 retry，界面沉默（UX-15）。它应该变成一句用户能读的话：
   「正在通过中继连接，可能较慢」。
3. **H-07 自建 relay** 从"独立价值"升级为"与本故障直接相关"——**我此前说它
   与本次故障无关，那个判断错了**。relay 路径的质量直接决定 connect 能不能
   在超时内完成。但它不是唯一解：超时分开之后，即使走 n0 公共 relay 也能连上。
