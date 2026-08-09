// T6 (H-10b): 备份范围——用户选中的相册（MediaStore bucket ids）。
// null = 从未选择 = 全量（兼容旧行为）；空集 = 一个都不备（用户全取消，
// 合法状态：手动备份会显示"没有可备份的相册"）。
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

    fun saveSelectedBucketIds(ids: Set<Long>) {
        prefs.edit().putString("bucket_ids", ids.sorted().joinToString(",")).apply()
    }
}
