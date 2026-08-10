// T6 (H-10b): 备份范围——用户选中的相册（MediaStore bucket ids）。
// null = 从未选择 = 全量（兼容旧行为）；空集 = 一个都不备（用户全取消，
// 合法状态：手动备份会显示"没有可备份的相册"）。
// MOB-02: 新增 knownBucketIds——「最近一次保存范围时看到的全部相册」，
// 新相册判定基准（选过子集后新出现的相册默认不包含 + 标「新」徽标）。
package com.hawkeyexb.ppass.backup

import android.content.Context

class BackupScopeStore(context: Context) {
    private val prefs =
        context.getSharedPreferences("backup_scope", Context.MODE_PRIVATE)

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
}
