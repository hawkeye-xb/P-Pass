// UX-13（2026-08-26 真机）：验收人原话「暂停之后，没有重新开始的按钮？」
//
// ## 缺陷是什么
//
// 英雄区那个按钮只在 `busy`（= 进行中）时渲染。一暂停 `busy` 变 false，
// 按钮**整个消失**——首页没有任何「继续」入口，想续传只能进设置页找那个
// 低调的「立即备份」。这与 UX-01 卡面自己写的语义冲突（「进行中再点 =
// 暂停……再点一次 = 续传」）：管线侧支持续传，界面上没有那个「再点一次」
// 可点。
//
// ## 为什么需要落一个时刻，而不是直接看 work 状态
//
// 「用户主动暂停」与「本来就没事干」都映射到 `BackupUiState.Idle`，界面
// 分不出来。而**直接靠「最近一条终态是 CANCELLED」判断是不可靠的**：
// WorkManager 取消时拿不到 `outputData`（MOB-33 实测），于是 CANCELLED
// 记录没有 `KEY_FINISHED_AT` 戳，在 `uiStateOf` 的「按戳取最大」选取里
// （MOB-31 立的规矩）恒被当成上古记录——只要盘上还有任何一条带戳的历史
// 成功记录，那条 CANCELLED 就永远选不中。
//
// 所以这里记的是**用户按下暂停的那一刻**（一个已经发生的事实），再与
// work 的真实状态合成（见 [pausedAfterOf]）。这不违反 MOB-33 那条「界面
// 不许自己编状态」：合成时仍然要求「没有 work 在跑」，所以点完暂停而字节
// 还在传的那段时间，界面照旧显示进行中 + 「暂停」，不会当场假装停了。
//
// ## 为什么是时刻而不是布尔
//
// 布尔要有人负责清。清早了（点击后马上清）等于没记；清晚了（等下一轮开跑
// 才清）中间有一段窗口谁也说不清该谁清，还得跟五条触发通道各自的开跑时机
// 打交道。时刻不需要清除时机就能自证过期：只要出现**比它更新的运行**，
// 这次暂停就已经被覆盖了。
//
// ⚠️ UX-14 修正了这句话的后半截。原文写的是「比它更新的**完成记录**」——
// 那假设每一轮都会留下终态戳，而失败重试走 Result.retry()、结构上留不下
// （WorkManager 的 retry 不接受 outputData）。真机上的后果是把「传输中断」
// 显示成「被暂停」。锚点因此从「跑完」扩到「开跑」，见 [RunStartPrefs]。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 用户按下「暂停」的时刻（unix ms；0 = 没有待续传的暂停）。 */
@Serializable
data class PauseState(val pausedAt: Long = 0L)

/**
 * 「用户暂停过」的落盘（tmp+rename 崩溃安全，与 [ReuploadNoticePrefs]
 * 同款）。放在 per-remote 目录 `backup-state/<daemonNodeId>/`——断开配对时
 * `deleteRecursively` 顺手清掉，一次暂停不会比它所属的那段配对活得更久。
 *
 * 必须落盘（而不是只留内存）：暂停后杀 App 重开，那个「继续」按钮必须还在
 * 原地，否则用户重开一次 App 就再也找不到续传入口——正是本卡的缺陷本体。
 */
class PausePrefs(private val dir: File) {
    private val file = File(dir, "pause_state.json")
    private val json = Json { ignoreUnknownKeys = true }

    /** 读盘失败/无文件一律当「没暂停过」——绝不因为一个偏好文件崩 App。 */
    fun pausedAt(): Long =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(PauseState.serializer(), file.readText()).pausedAt
            }.getOrDefault(0L)
        } else 0L

    fun setPausedAt(ts: Long) {
        dir.mkdirs()
        val tmp = File(dir, "pause_state.json.tmp")
        tmp.writeText(json.encodeToString(PauseState.serializer(), PauseState(ts)))
        check(tmp.renameTo(file)) { "cannot persist pause_state.json" }
    }
}

/** UX-14: 一轮备份**开跑**的时刻（unix ms；0 = 从没跑过）。 */
@Serializable
data class RunStartState(val startedAt: Long = 0L)

/**
 * UX-14: 「最近一轮备份是什么时候**开跑**的」落盘（同目录、同款 tmp+rename，
 * 断开配对随 `backup-state/<daemonNodeId>/` 一起清）。
 *
 * ## 为什么需要它
 *
 * [pausedAfterOf] 原来只拿「最新的带戳完成记录」判断这次暂停有没有被后来的
 * 运行覆盖。而失败重试走 `Result.retry()`，**WorkManager 的 retry 结构上
 * 拿不到 `outputData`**，那一轮不可能盖 [KEY_FINISHED_AT]。
 *
 * 真机后果（2026-08-26 test.8）：用户暂停 → 点继续 → 续传那一轮传到
 * `sending 54/198` 时 `IrohError ConnectionLost(TimedOut)` → retry → 不盖戳
 * → 判据眼里那次暂停「还没被覆盖」→ 界面又冒出「继续」。验收人原话：
 * 「怎么传一半自己暂停了……按道理我没碰到。」
 *
 * UX-13 卡面写过「时刻不需要清除时机就能自证过期：只要出现比它更新的完成
 * 记录，这次暂停就已经被覆盖了」——**那句话假设每一轮都会留下终态戳**，
 * 而 retry 这条路留不下。所以锚点要从「跑完」换成「开跑」：一轮开跑就意味着
 * 这次暂停被消费掉了，那一轮后来是成功、失败还是被砍，由它自己的状态表达。
 */
class RunStartPrefs(private val dir: File) {
    private val file = File(dir, "run_start.json")
    private val json = Json { ignoreUnknownKeys = true }

    /** 读盘失败/无文件一律当「从没跑过」——绝不因为一个偏好文件崩 App。 */
    fun startedAt(): Long =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(RunStartState.serializer(), file.readText()).startedAt
            }.getOrDefault(0L)
        } else 0L

    fun setStartedAt(ts: Long) {
        dir.mkdirs()
        val tmp = File(dir, "run_start.json.tmp")
        tmp.writeText(json.encodeToString(RunStartState.serializer(), RunStartState(ts)))
        check(tmp.renameTo(file)) { "cannot persist run_start.json" }
    }
}

/**
 * 「现在处于用户暂停态」的判据。**纯函数**，JVM 单测直接覆盖。
 *
 * 三个条件缺一不可：
 *
 * - `!anyRunning`：有 work 在跑就是进行中，不是暂停。这条守住 MOB-33
 *   的红线——点完暂停而字节还在传的那段时间，界面必须继续说进行中。
 * - `pausedAt > 0`：用户确实按过暂停（这是记录下来的事实，不是推断）。
 * - `newestFinishedAt < pausedAt`：这次暂停**还没有被后来跑完的运行覆盖**。
 * - `lastStartedAt < pausedAt`（UX-14）：也没有被后来**开跑过**的运行覆盖。
 *   少了这一项，一轮开跑之后失败重试（`Result.retry()` 拿不到 outputData
 *   → 不盖戳）会让那次暂停永不过期，界面把「传输中断」说成「被暂停」。
 *
 * 两个锚点取**更晚**的那个：跑完是开跑的子集，但开跑的那一轮可能还没跑完
 * （或永远跑不完），所以两者都要看。
 *
 * @param newestFinishedAt 全部**可展示**终态记录里最大的 [KEY_FINISHED_AT]
 *   （0 = 一条带戳的都没有）。必须从已排除 [KEY_SKIPPED] 空转轮的列表里算
 *   ——空转轮按 MOB-31 的不变量也盖戳，且往往紧跟在暂停之后落地，不排除
 *   它就会把刚发生的暂停当成「已被覆盖」。
 * @param lastStartedAt [RunStartPrefs] 落盘的最近一轮**开跑**时刻（0 = 从没
 *   跑过）。同理**不含空转轮**——抢不到互斥门那一轮什么也没干，不算开跑。
 */
internal fun pausedAfterOf(
    pausedAt: Long,
    newestFinishedAt: Long,
    anyRunning: Boolean,
    lastStartedAt: Long = 0L,
): Boolean = !anyRunning && pausedAt > 0L &&
    newestFinishedAt < pausedAt && lastStartedAt < pausedAt
