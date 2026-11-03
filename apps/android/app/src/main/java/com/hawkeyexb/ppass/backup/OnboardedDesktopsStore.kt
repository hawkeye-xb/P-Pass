// MOB-114（#455）：「这台电脑以前连过吗」的唯一事实来源。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.io.atomicReplace
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
private data class OnboardedDesktopsData(
    val nodeIds: Set<String> = emptySet(),
    /** onboarding 闸门（2026-11-03 判断 A）：升级后的一次性补记做过没有。老文件没有这个字段 = 没做过。 */
    val initialized: Boolean = false,
)

/**
 * 哪些桌面（按 daemonNodeId）在这台手机上**走完过 onboarding**。
 *
 * ## 为什么要单独一份文件
 *
 * 判据原来是 `files/flow-state/<daemonNodeId>/discovery-ledger.json` 在不在。
 * #413 的 `migrateLegacyFlowState` 一次性删了整个 `flow-state/`，之后没有任何
 * 生产代码再写它——判据恒为 false，连回同一台电脑也被当成新电脑：后台备份
 * 意图被清掉、重走选相册（#455）。
 *
 * 能拿来当判据的事实，必须**活过断开、配对失效、重新配对、换台电脑再换回来、
 * order 库升 schema**这几条路。现有的事实一条都不满足（逐条见 PR #455 的表）：
 * `pairing.json` 与 `backup-state/<id>/` 断开就删；order 表换台桌面就
 * `claimOwner` 清空、升版本就整表 DROP；`AutoBackupPrefs` 是全局的；
 * 每台桌面的相册范围活得下来，但 MOB-92 的一次性认领会让一台**从没连过**的
 * 桌面继承老的全局范围，单看它会把新桌面误判成老桌面。
 *
 * 所以记一个只为这件事存在的标记：
 * - 放在 `filesDir` 顶层——**不许**挪进 `flow-state/`、`backup-state/<id>/`
 *   这类会被整目录删掉的地方；
 * - 只增不减：断开、配对失效都不碰它（`clearLocalPairing` 的源文本门禁钉住）。
 *   清应用数据时跟着一起没，那时本来就该从零开始。
 * - 文件损坏 = 空集合 = 按新电脑走 onboarding。宁可多问一次，不许把新电脑
 *   当旧电脑静默继承后台备份意图。
 *
 * 纯文件 IO，JVM 单测能真跑往返（本仓没有 Robolectric）。
 */
class OnboardedDesktopsStore(private val dir: File) {
    private val file = File(dir, "onboarded_desktops.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun wasOnboarded(daemonNodeId: String): Boolean =
        daemonNodeId.isNotBlank() && daemonNodeId in load().nodeIds

    /** #130：这台手机是否走完过任何一次 onboarding（判「老用户」用）。 */
    fun anyOnboarded(): Boolean = load().nodeIds.isNotEmpty()

    fun markOnboarded(daemonNodeId: String) {
        if (daemonNodeId.isBlank()) return
        val current = load()
        if (daemonNodeId in current.nodeIds) return
        write(current.copy(nodeIds = current.nodeIds + daemonNodeId))
    }

    /**
     * onboarding 闸门（2026-11-03 判断 A）：升级后第一次启动，按现状给**当时配着的那台**补记一次，之后不再补。
     *
     * 补记要回答的是「升级那一刻用户是不是已经在用这台电脑」，是一次性的初值，不是长期规则。每次进照片页都补
     * 的话，一台从没连过的新电脑经 MOB-92 一次性认领拿到老的全局范围，范围非空，就被误记成「连过」。
     *
     * - 没做过（文件不存在、或老文件没有 `initialized`）：[daemonNodeId] 有值、没记录、[scopeNonEmpty] → 补记；
     *   然后落「已初始化」。返回这次有没有补记。
     * - 文件读不出来：按「已初始化」处理，不补——和「损坏 = 空集合 = 多问一次」同方向。
     * - [scopeNonEmpty] 惰性：不补的情况下不读范围（读范围会触发 MOB-92 认领）。
     */
    fun initIfAbsent(daemonNodeId: String?, scopeNonEmpty: () -> Boolean): Boolean {
        val current = read() ?: return false
        if (current.initialized) return false
        val backfill = !daemonNodeId.isNullOrBlank() && daemonNodeId !in current.nodeIds && scopeNonEmpty()
        val ids = if (backfill) current.nodeIds + daemonNodeId!! else current.nodeIds
        write(current.copy(nodeIds = ids))
        return backfill
    }

    /** 新版本写下的文件一律带「已初始化」：判断 A 的补记只在升级后第一次启动做。 */
    private fun write(data: OnboardedDesktopsData) {
        dir.mkdirs()
        val tmp = File(dir, "onboarded_desktops.json.tmp")
        tmp.writeText(json.encodeToString(OnboardedDesktopsData.serializer(), data.copy(initialized = true)))
        check(atomicReplace(tmp, file)) { "cannot persist onboarded_desktops.json" }
    }

    private fun load(): OnboardedDesktopsData = read() ?: OnboardedDesktopsData()

    /** null = 文件在、但读不出来。 */
    private fun read(): OnboardedDesktopsData? =
        if (file.isFile) {
            runCatching { json.decodeFromString(OnboardedDesktopsData.serializer(), file.readText()) }.getOrNull()
        } else {
            OnboardedDesktopsData()
        }
}

/**
 * 连回的是不是以前连过的那台：**走完过 onboarding**，并且**这台**桌面的相册
 * 范围还在（MOB-92：范围必须按这台问，否则 macOS → Windows → macOS 会用着
 * Windows 的范围直接回首页）。
 *
 * [scopeNonEmpty] 是惰性的：标记不在就不去读范围——读范围会触发 MOB-92 的
 * 一次性认领，不该让一台新电脑因为"被问了一句"就认领走老的全局范围。
 */
fun isKnownDesktop(
    store: OnboardedDesktopsStore,
    daemonNodeId: String,
    scopeNonEmpty: () -> Boolean,
): Boolean = store.wasOnboarded(daemonNodeId) && scopeNonEmpty()
