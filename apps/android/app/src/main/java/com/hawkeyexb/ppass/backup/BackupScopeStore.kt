package com.hawkeyexb.ppass.backup

import android.content.Context
import android.content.SharedPreferences
import com.hawkeyexb.ppass.transport.PairingStore

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

    /** Selected album ids; null = everything (never scoped). */
    fun selectedBucketIds(): Set<Long>? {
        val raw = prefs.getString("bucket_ids", null) ?: return null
        return raw.split(",").mapNotNull { it.toLongOrNull() }.toSet()
    }

    /** MOB-02: 最近一次保存范围时看到的全部相册 id；null = 从未选过范围
     *  （全量模式——新相册自动包含，无「新」徽标）。 */
    fun knownBucketIds(): Set<Long>? {
        val raw = prefs.getString("known_bucket_ids", null) ?: return null
        return raw.split(",").mapNotNull { it.toLongOrNull() }.toSet()
    }

    /** MOB-02: 保存范围的同时记录当前全部相册集合——下次进来不在
     *  known 里的相册标「新」、默认不勾选（选中集语义天然排除）。 */
    fun saveScope(selected: Set<Long>, allCurrent: Set<Long>) {
        prefs.edit()
            .putString("bucket_ids", selected.sorted().joinToString(","))
            .putString("known_bucket_ids", allCurrent.sorted().joinToString(","))
            .apply()
    }

    companion object {
        internal const val LEGACY_PREFS = "backup_scope"

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
