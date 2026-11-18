// #1788：本机是否发起过至少一次相册权限申请的发射记录（SharedPreferences）。
// shouldShowRequestPermissionRationale 把「从没申请过」与「被永久拒绝」都读成 false，单靠它
// 分不开；自己的发射记录补上这一维——申请过且 rationale=false 才是真被锁（只剩应用详情页）。
// 断开清单：本机权限史，与配对无关，KEEP（DisconnectStateManifest.ALBUM_ACCESS_PROMPT）。
package com.hawkeyexb.ppass.backup

import android.content.Context
import com.hawkeyexb.ppass.log.PLog

class AlbumAccessPromptPrefs(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * 发射过至少一次相册权限申请吗。没存值按当前真实状态算初值（AGENTS.md「读现状初始化，
     * 不写迁移」）：已授权、或被拒过一次（rationale=true）都说明申请过；rationale=false 分不出
     * 「没申请过」与「被永久拒绝」，按没申请过算（点击才申请；真被锁的用户点一次后当场翻面）。
     */
    fun requestedOnce(photoGranted: Boolean, rationale: Boolean?): Boolean {
        if (prefs.contains(KEY_REQUESTED)) return prefs.getBoolean(KEY_REQUESTED, false)
        return initialAlbumRequestedOnce(photoGranted, rationale)
    }

    /** 发射相册权限申请成功后记一笔；写不进去只记日志——下次冷启动回到初值口径，行为不坏。 */
    fun markRequested() {
        val wrote = prefs.edit().putBoolean(KEY_REQUESTED, true).commit()
        if (!wrote) PLog.w("PPassScope", "album access: cannot persist requested-once record")
    }

    companion object {
        private const val PREFS = "album_access_prompt"
        private const val KEY_REQUESTED = "requested_once"

        /**
         * 发射记录没存值时的初值（纯判定，单测直接跑）。[rationale] 为 null = 读不到
         * （context 不是 Activity），同 rationale=false 处理。
         */
        internal fun initialAlbumRequestedOnce(photoGranted: Boolean, rationale: Boolean?): Boolean =
            photoGranted || rationale == true
    }
}
