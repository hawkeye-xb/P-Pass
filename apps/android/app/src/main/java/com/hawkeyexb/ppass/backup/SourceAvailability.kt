// #1788：备份来源可用性的统一口径——「现在还有没有能继续备份的来源」。
// 开关、英雄区、通知、设置页要读的同一份口径；本卡只交付判定本体，展示与通知接线归 #1789，
// 接线前不要声称已生效。folder-only 不被全局权限门控误报全停。对齐 iOS `Live/SourceAvailability.swift`；
// Android 的范围存值是 Long 集合，目录来源带 FOLDER_ID_FLAG（iOS 是 "folder:" 前缀字符串）。
// 纯判定、零 Android 框架依赖，JVM 单测直接可测。
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

    /** 已选相册、照片权限未完整且没有目录来源：自动备份真的停了，出停止状态并带「去设置」。空范围缺的是来源，不算这条。 */
    val showsGlobalPhotoBlock: Boolean get() =
        autoRule && photoAccess != MediaAccess.FULL && !hasUsableFolder && hasSelectedAlbum

    /** 目录 + 相册混合、照片权限未完整：文件夹还在传，只把相册侧说成「未完整授权」并给「调整范围」出口。 */
    val mixedAlbumIncomplete: Boolean get() = autoRule && photoAccess != MediaAccess.FULL && hasUsableFolder && hasSelectedAlbum

    /** 没有照片权限、也没有目录来源时，相册-only 的旧停止提示仍要出。 */
    val showsDeniedPhotoHint: Boolean get() = photoAccess == MediaAccess.NONE && !hasUsableFolder

    /** 仅没有可用目录来源的部分授权才需要引导去系统设置申请完整权限。 */
    val needsFullPhotoAccessSettings: Boolean get() = photoAccess == MediaAccess.PARTIAL && !hasUsableFolder

    companion object {
        /**
         * 目录来源可用吗——复用引擎的同一份有效范围判据（[effectiveBackupScope]）：新版勾选存值里的
         * 目录必须还在登记表里（移除过的目录不算可用），旧版没有勾选存值（selected == null）按登记
         * 目录读现状初始化，范围读失败（存值解不出来、saved 落到 null）同样走这个回退。
         * 通知侧与页面跟引擎永远同一份口径，不会各自漂移。
         */
        fun hasUsableFolder(selected: Set<Long>?, known: Set<Long>, existingFolders: Set<Long>): Boolean =
            effectiveBackupScope(
                saved = selected?.let { BackupScope(it, sinceSec = null) },
                knownSourceIds = known,
                existingFolderBuckets = existingFolders,
                sinceSec = null,
            )?.buckets?.any(::isFolderId) == true

        /** 通知侧判定与页面同一份口径：目录可用，或完整授权下已选且存在的相册，才算有可用来源。 */
        fun usableSource(
            selected: Set<Long>?,
            known: Set<Long>,
            existingFolders: Set<Long>,
            existingAlbums: Set<Long>?,
            photoAccess: MediaAccess,
        ): Boolean {
            if (hasUsableFolder(selected, known, existingFolders)) return true
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
