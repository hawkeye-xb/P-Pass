package com.hawkeyexb.ppass.backup

import android.content.Context
import android.content.SharedPreferences
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.PairingStore

/** #1020：备份范围的三种读法（对位 iOS：`savedScope` 返回 nil / 集合 / 抛出）。 */
sealed interface ScopeRead {
    /** 从未保存过范围。 */
    data object NeverSaved : ScopeRead

    data class Saved(val ids: Set<Long>) : ScopeRead

    /** 存了东西但读不出来——不是「从未保存」，界面要如实说「读不到」。 */
    data class Unreadable(val cause: Throwable) : ScopeRead
}

/**
 * 备份范围（选了哪些相册）——**每台桌面一份**。
 *
 * ## MOB-92：为什么要分
 *
 * 交付账本按桌面分（`files/flow-state/<daemonNodeId>/`），范围原本不分：
 * 一个写死的全局 `backup_scope`。于是
 *
 * > macOS 选 7 个相册 → 断开 → 连 Windows 选 2 个 → 断开 → 连回 macOS
 *
 * 回到 macOS 拿到的是给 Windows 选的那 2 个，而且因为
 * `MainActivity.hasExistingLedgerFor` 看到「范围非空」就直接回首页、不重走
 * onboarding，用户连重选的机会都没有——**静默用着错的范围开始备份**。
 *
 * `known_bucket_ids`（MOB-02 的「新相册」判据基线）同样被覆盖，切回来之后
 * 「哪些是新相册」也是错的。
 *
 * ## 未配对时读哪一份
 *
 * 落回历史上那个全局名字。未配对时没有「哪台桌面」可言，而这也正是下面
 * 迁移要读的那一份。
 */
class BackupScopeStore(context: Context, daemonNodeId: String? = null) {
    private val appContext = context.applicationContext
    private val nodeId: String? =
        daemonNodeId ?: PairingStore(appContext.filesDir).load()?.daemonNodeId

    private val prefs: SharedPreferences by lazy {
        val id = nodeId
        if (!id.isNullOrBlank()) adoptLegacyScopeOnce(appContext, id)
        appContext.getSharedPreferences(scopePrefsName(id), Context.MODE_PRIVATE)
    }

    /** 选中的相册 id。null = 从未保存过范围——**不是**「全部」：引擎把 null 与空集都当成一张都不在范围内
     *  （MOB-40；#541 起设置行也按这个显示「未选相册」）。
     *  #1020：读不出来（[readScope] 为 [ScopeRead.Unreadable]）也返回 null——引擎记日志后按空范围，
     *  需要区分「读不到」与「从未保存」的界面读 [readScope]。 */
    fun selectedBucketIds(): Set<Long>? = when (val read = readScope()) {
        ScopeRead.NeverSaved -> null
        is ScopeRead.Saved -> read.ids
        is ScopeRead.Unreadable -> {
            PLog.w(TAG, "backup-scope: unreadable, treating as no album selected", read.cause)
            null
        }
    }

    /** #1020（对位 iOS `MediaLibrary.savedScope` 抛出）：范围的三种读法——从未保存 / 已保存 / 读不出来。 */
    fun readScope(): ScopeRead = try {
        parseScope(prefs.getString(KEY_BUCKETS, null))
    } catch (e: Exception) {
        ScopeRead.Unreadable(e)
    }

    /** MOB-02: 最近一次保存范围时看到的全部相册 id；null = 从未选过范围
     *  （选相册页不标「新」徽标；范围本身仍是空的，见 [selectedBucketIds]）。 */
    fun knownBucketIds(): Set<Long>? {
        val raw = prefs.getString(KEY_KNOWN, null) ?: return null
        return raw.split(",").mapNotNull { it.toLongOrNull() }.toSet()
    }

    /**
     * #1263：范围的开始时间（epoch 秒）；null = 全部。没有这个字段（老范围）或读不出来一律按「全部」——
     * 不许因为读不懂就悄悄把范围缩小。
     */
    fun sinceSec(): Long? = runCatching { prefs.getString(KEY_SINCE, null)?.toLongOrNull() }.getOrNull()

    /** 引擎与计数用的完整范围；从未保存 / 读不出来为 null（= 一张都不在范围内，见 [selectedBucketIds]）。 */
    fun scope(): BackupScope? = selectedBucketIds()?.let { BackupScope(it, sinceSec()) }

    /** MOB-02: 保存范围的同时记录当前全部相册集合——下次进来不在
     *  known 里的相册标「新」、默认不勾选（选中集语义天然排除）。
     *  #1263：[sinceSec] 一起落盘（null = 全部）。 */
    fun saveScope(selected: Set<Long>, allCurrent: Set<Long>, sinceSec: Long?) {
        // #1020：commit 而不是 apply——apply 的写盘失败只在系统日志里，调用方永远不知道没存上。
        val edit = prefs.edit()
            .putString(KEY_BUCKETS, selected.sorted().joinToString(","))
            .putString(KEY_KNOWN, allCurrent.sorted().joinToString(","))
        if (sinceSec == null) edit.remove(KEY_SINCE) else edit.putString(KEY_SINCE, sinceSec.toString())
        check(edit.commit()) { "cannot persist backup scope" }
        PLog.i(TAG, "backup-scope: saved ${selected.size} albums since=${sinceSec ?: "all"}")
    }

    companion object {
        internal const val LEGACY_PREFS = "backup_scope"
        private const val KEY_BUCKETS = "bucket_ids"
        private const val KEY_KNOWN = "known_bucket_ids"
        private const val KEY_SINCE = "since_sec"
        private const val TAG = "PPassScope"

        /**
         * #1020：存下来的字符串 → 三种读法。空串 = 保存了空集；任何一段解析不出数字 = 读不出来——
         * 不再 `mapNotNull` 静默丢掉坏的那段（那会把范围悄悄缩小，用户看不到）。
         * SharedPreferences 自己吞掉的 XML 损坏（整份当空）在这里分辨不出，只能当「从未保存」。
         */
        internal fun parseScope(raw: String?): ScopeRead {
            if (raw == null) return ScopeRead.NeverSaved
            if (raw.isEmpty()) return ScopeRead.Saved(emptySet())
            val ids = raw.split(",").map { token ->
                token.toLongOrNull() ?: return ScopeRead.Unreadable(IllegalStateException("bad album id in saved scope: '$token'"))
            }
            return ScopeRead.Saved(ids.toSet())
        }

        /** 老的全局那份被哪台桌面认领了——只认领一次。 */
        internal const val KEY_ADOPTED_BY = "adopted_by"

        /**
         * 范围存在哪一份 prefs 里。
         *
         * 未配对（nodeId 为空）时落回历史上那个全局名字：没有「哪台桌面」
         * 可言，而这也正是 [decideAdoption] 要读的那一份。
         *
         * 纯函数，无 Android 依赖——本仓没有 Robolectric，判据必须能在 JVM
         * 单测里直接跑（同 `flowReuploadNoticeCount` / `externalDeleteNotice`
         * 的惯例）。
         */
        internal fun scopePrefsName(nodeId: String?): String =
            if (nodeId.isNullOrBlank()) LEGACY_PREFS else "$LEGACY_PREFS-$nodeId"

        /** [decideAdoption] 的三种结局。 */
        internal enum class Adoption {
            /** 已经被某台桌面认领过了，什么都别做。 */
            ALREADY_CLAIMED,

            /** 老的那份有内容，复制给这台并盖章。 */
            COPY_THEN_STAMP,

            /** 老的那份是空的，只盖章——防止以后某台存进来的范围被下一台
             *  当成「历史遗留」继承走。 */
            STAMP_ONLY,
        }

        /**
         * MOB-92 迁移判据：老的全局范围该不该归给 [nodeId]。
         *
         * 升级时用户手上就一份范围，它属于当时配对着的那台。第一个来取范围
         * 的 nodeId 认领它，并留记号——**只认领一次**，否则之后连上的每一台
         * 新桌面都会继承这份，等于把 bug 换了个形状。
         */
        internal fun decideAdoption(alreadyAdoptedBy: String?, legacyBuckets: String?): Adoption =
            when {
                !alreadyAdoptedBy.isNullOrBlank() -> Adoption.ALREADY_CLAIMED
                legacyBuckets.isNullOrBlank() -> Adoption.STAMP_ONLY
                else -> Adoption.COPY_THEN_STAMP
            }

        /**
         * MOB-92 迁移：把历史上那份全局范围归给一台桌面。
         *
         * 升级时用户手上就一份范围，它属于当时配对着的那台。第一个来取范围
         * 的 nodeId 认领它，并在老 prefs 上留记号——**只认领一次**，否则
         * 之后连上的每一台新桌面都会继承这份，等于把 bug 换了个形状。
         *
         * 认领是**复制**不是移动：老 prefs 原样留着，万一判断错了还能追溯。
         */
        private fun adoptLegacyScopeOnce(context: Context, nodeId: String) {
            val legacy = context.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
            val buckets = legacy.getString("bucket_ids", null)
            when (decideAdoption(legacy.getString(KEY_ADOPTED_BY, null), buckets)) {
                Adoption.ALREADY_CLAIMED -> return
                Adoption.STAMP_ONLY -> Unit
                Adoption.COPY_THEN_STAMP ->
                    // 认领是**复制**不是移动：老 prefs 原样留着，万一判断错了
                    // 还能追溯。
                    context.getSharedPreferences(scopePrefsName(nodeId), Context.MODE_PRIVATE)
                        .edit()
                        .putString("bucket_ids", buckets)
                        .putString("known_bucket_ids", legacy.getString("known_bucket_ids", null))
                        .apply()
            }
            legacy.edit().putString(KEY_ADOPTED_BY, nodeId).apply()
        }
    }
}
