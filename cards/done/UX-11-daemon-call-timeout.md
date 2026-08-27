# UX-11 daemon 请求无超时——真死机后手机永久卡"正在读取"　级别 L1【严重，用户真机反馈 2026-08-12】

## 背景

用户把家里电脑上的 P-Pass 桌面服务删了/停了，手机端理应检测不到、
报个错——但实际是永久停在"正在读取"的 loading 态，一直不报错。用户
明确判定这是"比较严重的一个状态展示问题"。

## 根因

`DaemonClient.kt` 的 `call()`（所有 RPC 走这一个函数）和 `connectRaw()`
（上传/下载复用）直接 `ep.connect(addr, alpn)`，**零超时**。iroh 的
`connect()` 本身不带超时——对手已经完全不在（daemon 进程杀了/电脑关了）
时，连接建立可能无限期悬挂，从不抛异常。任何依赖 daemon 往返的 UI 路径
因此继承这个无界挂起：`PhotosScreen` 的 `LaunchedEffect` 里 `try { loader
.page(null) } catch { error = ... } finally { loading = false }` 永远
不会走到 `catch`/`finally`——`loading` 恒为 true，页面恒显示"正在读取
家里的照片…"，没有任何报错路径可达。同样受影响的还有 Home 的三元组
校准、手动"立即备份"等一切经 `DaemonClient.call` 的路径——只是
Photos tab 是这次撞见的那个。

## 修法

在 `DaemonClient.kt` 加一层有界超时，不逐个改调用点：

1. `call()`：`withTimeout(CONNECT_TIMEOUT_MS)` 包住整个往返（connect +
   send + recv），超时抛 `DaemonUnreachableException`（自定义、继承
   `IOException`，**故意不是** `CancellationException`）。
2. `connectRaw()`（上传/下载复用的原始连接）：只给"能不能连上"这一步
   加超时（`connectBounded` 辅助函数），会话本身（大文件传输）不受
   这条超时约束——语义不同，不能混着包。
3. `CONNECT_TIMEOUT_MS = 15_000`——参照 `MainActivity` 断开连接流程里
   已有的 `withTimeout(5_000) { client.unpair(peer) }`（作者已经预料到
   连接会悬挂，在那一个调用点局部加了超时）；这次统一收到 client 层，
   给中继/打洞更宽松的时间窗（loading 类 UX 比断开连接更能容忍等待）。

**为什么不能让超时异常继承 `CancellationException`**：
`BackupUiStateHolder.backupNow` 的 catch 块里有
`if (t is CancellationException) throw t`——这条判断本是为了保留
"再点一次=暂停"的语义（用户主动取消不算失败）。如果超时异常也披着
`CancellationException` 的外衣，会在这里被当成"用户暂停了"直接重新
抛出、逃过 `Trouble` 状态赋值，备份失败会**静默消失**而不是显示红卡——
这条链路上还会再制造一个"卡住不报错"的同类 bug。所以专门定义了一个
不继承 `CancellationException` 的 `DaemonUnreachableException`。

## 可执行验收

1. android 全量单测绿（iroh 是 native FFI，无法在 JVM 纯单测里模拟
   真实网络悬挂——这条修复的验证只能走真机）。
2. 真机（挂用户）：桌面服务停掉后，停留在照片 tab 不动——15 秒左右
   应该从"正在读取"变成"没能连上电脑"的报错文案，不再无限期卡住。
3. 反证（人工推理，非自动化）：把 `withTimeout` 去掉 → 回归到本卡
   描述的 bug（真机验证过一次，不需要重复破坏性验证）。

## 收尾
android 全量单测绿；CI 待推 main 后盯 ci-android；真机验证挂用户。

---

## ✅ 验收记录（2026-08-12）

- 实现：见「修法」三项，`DaemonClient.call`/`connectRaw` 均已接线；
  debug 包已 `adb install -r` 装到用户日常用的真机（该真机当前正处于
  桌面服务已停的状态，天然具备验证条件，不需要额外构造故障场景）。
- CI：push `971c0e5` → main，ci-android 绿（1m42s）。
- 挂账（真机，用户）：停留照片 tab，确认约 15s 内从"正在读取"变成
  报错文案，而不是永久卡住。
