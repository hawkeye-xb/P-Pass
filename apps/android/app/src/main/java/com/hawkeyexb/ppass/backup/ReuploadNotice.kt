// MOB-37（2026-08-26）：重传告知不能只活在一条系统通知里。
//
// ## 缺陷是什么
//
// MOB-29 的告知只有一条系统通知，而且**天然一次性**：校准算出 lost →
// 发通知 → `removeMissing` 把这批 hash 从 confirmed 剔除 → 下一轮算不出
// 同一批 → 永远不会再提示。当初把这个「一次性」写成了优点（「连去重窗口
// 都不用做」），**那是把缺陷说成了优雅**：一次性 = 没有兜底 = 那一次发
// 失败就永久静默。失败路子不止一种——通知权限没授（Android 13+ 不主动
// 申请就永远拒绝）、渠道被关、系统丢弃、用户手滑划掉、锁屏时没看见。
//
// 真机现场（2026-08-26）：访达里删 3 张 → 重传**确实发生了**（21 秒后
// 传回来），验收人**没看到任何提示**。
//
// ## 修法：通知退化成「提醒你去看」，不再是唯一载体
//
// - 状态**落盘**（本文件），App 内可见（`ui/HomeNotices.kt`），
//   用户看过可 acknowledge。
// - **不重试通知**：重试只制造骚扰，而且治不了「用户当时没看」。
//   系统通知只在 acknowledged → unacknowledged 那一次跃变时发。
// - 关键判据：**即使通知发送抛异常，状态仍要在盘上**（见
//   [noteReuploadNotice] 的顺序与 runCatching）。
//
// ## 为什么必须独立存储（不许并入 BackupHealthPrefs）
//
// 形状照抄 MOB-28 的 `BackupHealthPrefs`（落盘 + App 内可见 +
// acknowledge），但**存储独立**：「后台备份被停过」与「照片被重传回来」
// 语义不同，混一个标志会互相清掉——用户点掉其中一条，另一条凭空消失。
//
// ## 为什么记 hash 集合而不是累加计数
//
// 手动通道与周期通道可以并发跑（MOB-33），两轮都可能在对方 `removeMissing`
// 之前看到**同一批** missing。累加 `count += lost.size` 会把 3 张记成 6 张
// ——一个编出来的数字。取并集则同一批重复登记是幂等的，张数由集合大小导出。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 重传告知的落盘状态。空集 = 没有待看的告知（含「用户已看过」）。 */
@Serializable
data class ReuploadNoticeState(
    /** 「我确认过、但库里已经没有」的 hash 并集——张数由它导出，不累加。 */
    val lost: Set<String> = emptySet(),
    /** 最近一次登记的时刻（unix ms；0 = 无记录）。 */
    val detectedAt: Long = 0L,
)

/** App 内该显示几张。0 = 不显示（判据只看落盘状态，**与通知是否送达无关**）。 */
internal fun reuploadNoticeCountOf(state: ReuploadNoticeState): Int = state.lost.size

/**
 * 重传告知的落盘（tmp+rename 崩溃安全，与 [BackupHealthPrefs] 同款）。
 *
 * 放在 per-remote 目录 `backup-state/<daemonNodeId>/`（与 `confirmed.json`、
 * `ReuploadQueue` 同处）——于是断开配对时 `clearConfirmedFor` 的
 * `deleteRecursively` 顺手把告知一起清掉，告知不会比它描述的那段配对活得更久。
 */
class ReuploadNoticePrefs(private val dir: File) {
    private val file = File(dir, "reupload_notice.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): ReuploadNoticeState =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(ReuploadNoticeState.serializer(), file.readText())
            }.getOrDefault(ReuploadNoticeState())
        } else ReuploadNoticeState()

    /**
     * 登记一批「会被传回来」的 hash。
     *
     * @return 这一次是否**从无到有**（acknowledged → unacknowledged 的跃变）。
     *   只有 true 才该发系统通知——已经有一条在等用户看的时候再发一条，
     *   就是「重试通知」，本卡明确不做。
     */
    fun record(lost: Set<String>, now: Long): Boolean {
        if (lost.isEmpty()) return false
        val before = load()
        save(ReuploadNoticeState(lost = before.lost + lost, detectedAt = now))
        return before.lost.isEmpty()
    }

    /** 用户在 App 里点了「知道了」——告知消失。新一批 lost 会重新显示。 */
    fun acknowledge() {
        save(ReuploadNoticeState(lost = emptySet(), detectedAt = load().detectedAt))
    }

    private fun save(state: ReuploadNoticeState) {
        dir.mkdirs()
        val tmp = File(dir, "reupload_notice.json.tmp")
        tmp.writeText(json.encodeToString(ReuploadNoticeState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist reupload_notice.json" }
    }
}

/**
 * 落盘 → 再发通知。**顺序是承重的，而且 notify 的异常必须吞掉。**
 *
 * 两条理由，缺一条这个 helper 就没有存在意义：
 *
 * 1. 先落盘，所以「通知发送抛异常」（权限没授、渠道被关、系统抛）之后
 *    状态仍在盘上——App 内那条告知照样出得来。本卡的关键判据。
 * 2. `calibrateConfirmed` 的契约是 `onLost` 跑在 `removeMissing` **之前**，
 *    两者在同一个 try 里。让 notify 的异常往上冒，`removeMissing` 就被跳过，
 *    这批 hash 留在 confirmed 里，下一轮校准重新算出同一批 → 又发一条通知。
 *    那正好破了「同一批状态不许发第二条系统通知」。
 *
 * 反过来，**落盘本身抛异常时让它往上冒是对的**：removeMissing 被跳过，
 * 这批 hash 留在 confirmed 里，下一轮校准会重新登记一次——告知不丢。
 */
internal fun noteReuploadNotice(
    prefs: ReuploadNoticePrefs,
    lost: Set<String>,
    now: Long,
    notify: () -> Unit,
) {
    if (lost.isEmpty()) return
    val fresh = prefs.record(lost, now)
    if (fresh) runCatching { notify() }
}
