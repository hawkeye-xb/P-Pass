# 自动备份规则缓存的到期判据：哨兵显式判断，不做减法

- 状态：提议
- 日期：2026-11-03
- 关联：#1317（P0 release-blocker）、#1272（引入 1 秒缓存）

## 结论

1. 「规则缓存该不该重读」抽成纯函数 `ruleCacheDue(nowMs, cachedAtMs)`；首读哨兵
   `RULE_CACHE_NEVER_MS = Long.MIN_VALUE` **显式判断**，不参与任何减法。
2. 哨兵只表示「从未读过」。新增缓存时间戳一律用同一个判据；不允许再写
   `now - cachedAt > …` 这种对哨兵做时间算术的代码。
3. 判据由 `RuleCacheDueTest` 钉住三种情形（首读、1 秒内、超过 1 秒）；反证是把判据改回减法后
   首读那条必须红。

## 背景

#1317：test.4 的 Android 上「自动备份」开着、范围也选了，却一张都不传。

`AndroidFlowRuntime.kt` 的 1 秒规则缓存（#1272 引入）用 `Long.MIN_VALUE` 当「还没读过」的哨兵：

```kotlin
var ruleCache = false
var ruleCachedAt = Long.MIN_VALUE
val ruleOn = {
    val now = SystemClock.elapsedRealtime()
    if (now - ruleCachedAt > 1_000L) { /* 重读 */ }
    ruleCache
}
```

`now - Long.MIN_VALUE` 在 64 位补码里溢出成负数，条件恒为 false，`ruleCache` 永远停在初始的
`false`。范围查询与逐张判断都走 `ruleOn()`，于是整条自动备份链路被静默关掉；每次进程重建都从
`MIN_VALUE` 重来，所以杀进程重开也无效。

## 决定

在 `crates` 之外的 Android 核心流程文件 `backup/flow/FlowCore.kt` 里加纯函数：

```kotlin
internal const val RULE_CACHE_NEVER_MS = Long.MIN_VALUE

/** 缓存该不该重读：首读（哨兵）必读，其余按 1 秒窗口。 */
internal fun ruleCacheDue(nowMs: Long, cachedAtMs: Long): Boolean =
    cachedAtMs == RULE_CACHE_NEVER_MS || nowMs - cachedAtMs > 1_000L
```

- `AndroidFlowRuntime.kt` 的两个读点都改用它，写入缓存时照旧记 `SystemClock.elapsedRealtime()`。
- 哨兵继续用 `Long.MIN_VALUE`：它是 `elapsedRealtime()` 不可能取到的值，而且「显式比较」比「拿一个
  魔法时间戳当边界」更难写错。
- `RuleCacheDueTest` 三条：`cachedAt = MIN_VALUE` 必读；`now - cachedAt = 1000` 不读；
  `= 1001` 读。反证写成注释：把函数改回 `nowMs - cachedAtMs > 1_000L`，第一条红。

## 理由

- 「未知」与「很久以前」是两种状态。业界的时长计算都把未知单独表示（Rust
  `Instant::checked_duration_since`、Java `Duration.between` 对 null 的显式处理），而不是塞一个
  极值进算术。
- 这个 bug 的危险在于**静默**：开关亮着、界面没红，用户以为在备份。判据必须是纯函数、可单测、
  有反证，而不是埋在协程里的一个条件。
- 保留 1 秒缓存：范围扫描会逐张调用 `ruleOn()`，每次都读偏好会把 IO 放大到照片数级别。缓存窗口
  本身没问题，问题只在对哨兵做减法。

## 后果

- 首读必读一次；之后 1 秒内复用；自动备份恢复。协议、数据、身份都不变。
- 新增「缓存到期」逻辑必须复用 `ruleCacheDue` 或同型判据；再写减法视为缺陷。
- `FlowCore.kt` / `AndroidFlowRuntime.kt` 在 `apps/android/app/src/main/**` 必审区，本改动按核心流程
  走：ADR → 卡 → owner 批 core review。

## 备选（未采纳）

- **用 `0L` 当哨兵**：`SystemClock.elapsedRealtime()` 刚开机时可能很小，0 与真实时间不可区分，
  错误窗口虽短但同样静默。`Long.MIN_VALUE` 明确得多。
- **`cachedAt: Long? = null`**：语义最干净，但要改可空类型、装箱与两个读点；运行时 1 秒一次的性能
  差异可忽略，改动面却更大，收益不成比例。
- **去掉缓存**：每张照片都读一次规则偏好，范围大时把磁盘 IO 放大到照片数量级，不可接受。
