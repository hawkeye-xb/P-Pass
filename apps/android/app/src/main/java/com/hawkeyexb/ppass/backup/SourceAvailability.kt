// #1788：备份来源可用性的统一口径——「现在还有没有能继续备份的来源」。
// 开关、英雄区、通知、设置页都读这一份，不再各自拿「完整照片权限」当唯一判据，
// folder-only 不再被全局权限门控误报全停。对齐 iOS `Live/SourceAvailability.swift`；
// Android 的范围存值是 Long 集合，目录来源带 FOLDER_ID_FLAG（iOS 是 "folder:" 前缀字符串）。
// 纯判定、零 Android 框架依赖，JVM 单测直接可测；英雄区最终展示归 #1789 接线。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.folder.isFolderId

/** 四个输入（[autoRule] / [photoAccess] / [hasUsableFolder] / [hasSelectedAlbum]）之上的所有结论都是纯推导。 */
data class SourceAvailability(
    val autoRule: Boolean,
    val photoAccess: MediaAccess,
    val hasUsableFolder: Boolean,
    val hasSelectedAlbum: Boolean,
) {
    /** 只有目录来源：照片权限变差不产生任何停止状态。 */
    val folderOnly: Boolean get() = hasUsableFolder && !hasSelectedAlbum

    /** 有没有能继续备份的来源——目录可用，或完整授权下已选相册。有限 / 拒绝授权时相册不算来源（那几张只走「挑几张传」），文件夹照常。 */
    val hasUsableSource: Boolean get() = hasUsableFolder || (photoAccess == MediaAccess.FULL && hasSelectedAlbum)

    /** 纯相册范围、照片权限未完整：自动备份真的停了，出停止状态并带「去设置」。 */
    val showsGlobalPhotoBlock: Boolean get() = autoRule && photoAccess != MediaAccess.FULL && !hasUsableFolder

    /** 目录 + 相册混合、照片权限未完整：文件夹还在传，只把相册侧说成「未完整授权」并给「调整范围」出口。 */
    val mixedAlbumIncomplete: Boolean get() = autoRule && photoAccess != MediaAccess.FULL && hasUsableFolder && hasSelectedAlbum

    /** 没有照片权限、也没有目录来源时，相册-only 的旧停止提示仍要出。 */
    val showsDeniedPhotoHint: Boolean get() = photoAccess == MediaAccess.NONE && !hasUsableFolder

    /** 仅没有可用目录来源的部分授权才需要引导去系统设置申请完整权限。 */
    val needsFullPhotoAccessSettings: Boolean get() = photoAccess == MediaAccess.PARTIAL && !hasUsableFolder

    companion object {
        /**
         * 目录来源可用吗：新版勾选存值里勾了目录，或旧版按目录登记数算。
         * 旧版没有勾选存值（selected == null），不能把新版明确取消勾选（空集）当成有效范围。
         */
        fun hasUsableFolder(selected: Set<Long>?, known: Set<Long>, folderCount: Int): Boolean {
            if (selected?.any(::isFolderId) == true) return true
            val unified = (known + (selected ?: emptySet())).any(::isFolderId)
            return !unified && folderCount > 0
        }

        /** 通知侧判定与页面同一份口径：目录可用，或完整授权下已选且存在的相册，才算有可用来源。 */
        fun usableSource(
            selected: Set<Long>?,
            known: Set<Long>,
            folderCount: Int,
            existingAlbums: Set<Long>?,
            photoAccess: MediaAccess,
        ): Boolean {
            if (hasUsableFolder(selected, known, folderCount)) return true
            if (photoAccess != MediaAccess.FULL) return false
            // existingAlbums == null = 读不到相册（如没有照片权限），无从判断哪些还在：沿用已选个数
            // （与 ui.selectedExistingCount 同一口径）。
            val albumScope = selected?.filterNot(::isFolderId)?.toSet()
            val count = when {
                albumScope == null -> null
                existingAlbums == null -> albumScope.size
                else -> albumScope.count { it in existingAlbums }
            }
            return (count ?: 0) > 0
        }
    }
}
