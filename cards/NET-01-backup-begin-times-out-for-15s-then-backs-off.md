# NET-01 半小时内三次传输层失败——`backup.begin` 卡满 15 秒才超时　级别 L2

> 🟡 状态：已复现，等待可持续的 relay 窗口验证修复（暂不占当前槽位）
> 级别：**L2** · 阻塞：当前无可持续的蜂窝热点 / 跨网 relay 测试窗口

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

## 2026-08-27（另一轮真机会话）：三次静默复现,与本卡链条吻合

用户当天用 ALN-AL00（鸿蒙，5G+公司网络）反复"选相册→触发同步"，服务端
`audit_log` 显示：

```
11:41:06  pair.accepted（配对刚完成,当场前台操作）
11:41:22  backup.started → 7 个文件 ingest → backup.finished（唯一成功一次）
14:07:27  device.connected  ← 之后再无 backup.started
14:33:15  device.connected  ← 之后再无 backup.started
15:21:47  device.connected  ← 之后再无 backup.started（与 hilog 里 App 前台
                              事件时间差 6 秒,对得上"打开 App 顺手 ping 了
                              一下"）
```

`diag_event` 表全程零新增（没有 `authz.denied`，没有任何拒绝/报错记录）。

这与本卡"connect 落到 relay → 15s 超时 → backup.begin 从未送达 daemon →
零 backup.started"的链条**完全吻合**——服务端视角看到的就是"连上了、
然后沉默"，跟这条链条预测的形状一致。

**没能往前推进的部分**：daemon 侧只有 info 级日志，没能确认"连接尝试到底
有没有到网络层"（本卡待验证节提到的判决实验，需要 debug 级 daemon 日志）；
本轮也确认了鸿蒙这台机器上**拿不到 App 内部日志**（Anco 容器权限边界，
详见 `local-state.md`），所以没法从手机侧 logcat 交叉验证是 connect
阶段卡住还是别的原因。

**下一步（已跟用户对齐）**：用户回家换 **OPPO Reno8**（原生 Android，
`adb` 全功能）复测同一操作，拿到真实 logcat 后应该能直接看到
`DaemonClient.kt` 那个 15 秒超时错误串,坐实或推翻这条链条。

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

## 2026-09-11：三星连手机蜂窝热点的 relay 对照通过（本卡仍不关闭）

- 三星 SM-S9210 的默认路由切到热点 Wi-Fi；Mac 保持原网络。当前 main debug
  daemon 用 `RUST_LOG=info,transport=debug` 记录到同一手机的 inbound 注册为
  `Relay(https://aps1-1.relay.n0.iroh.link./)`，不是 LAN 对照。
- 在已选 Screenshots 范围新增一张隔离照片，强制运行生产 `MediaWatchJob` 后，
  Flow 项 `CONFIRMED`、`attemptCount=0`；daemon 审计出现 `ingest.new`，Android
  logcat 与 daemon 日志均无 `DaemonUnreachableException`、`ConnectionLost` 或
  timeout。
- 这证明「三星 + 此热点 + n0 relay」当前可完成一次 Flow，**不**证明 8/26 的
  15 秒失败已经修复，也不能据此改超时值。原始失败仍需 OPPO 原生 Android 的
  失败日志判定；手机测试源已清，后台备份开关和 device-idle 白名单均恢复原状。

## 2026-09-11：三星热点大视频重新复现（恢复当前槽位）

- 当前 main daemon + 三星 SM-S9210，手机连蜂窝热点、Mac 保持原网络。72 MB
  视频曾三秒确认；随后 288 MB 隔离视频的真实 Flow 在手机端连续三次报
  `DaemonUnreachableException: flow.fetch: no response from the computer within 15000ms`，
  进入 `FAILED_NEEDS_USER`。
- daemon debug 日志在这三次期间没有对应的成功或失败 `flow delivery` 记录；目前
  只能确定手机在 daemon 交付完成前耗尽 15 秒，尚不能把“请求未到达”与“到达后
  长 fetch 未完成”混为一谈。它与原卡“把建连、RPC、长数据 fetch 共用 15 秒”的
  缺口同类，但证据已从 `backup.begin` 扩展到 `flow.fetch`。
- 因此不能再以“三星小文件 relay 成功”降级本卡；OPPO 不再是前置。下一步应拆分
  建连、普通控制 RPC 与长 fetch 的 deadline，并用这条三星热点大视频回归验证。

## 2026-09-11：用户决定暂缓 relay 验证

当前没有可持续的蜂窝热点窗口，无法负责任地跑长视频 cross-network 回归；本卡保留
已复现证据，移出当前开发槽位。它只阻塞 relay 大文件的验收与 deadline 修复验证，
不阻塞同网/本地的 Flow 生命周期、撤销反馈和日志导出工作。
