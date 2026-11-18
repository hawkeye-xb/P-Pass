package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1788：备份来源可用性的统一口径（对齐 iOS `SourceAvailabilityTests.swift`）——
 * folder-only 不被全局照片权限门控误报全停；「自动备份已停止」只对真正没有可用来源的状态说。
 * 纯判定，JVM 单测直接可测；英雄区最终展示归 #1789 接线。
 */
class SourceAvailabilityTest {

    /**
     * 只有目录来源：照片权限全拒也不出「自动备份已停止」。
     * 反证：去掉 `!hasUsableFolder`，本条红。
     */
    @Test
    fun folderOnly_doesNotShowGlobalPhotoBlock() {
        val facts = SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = true, hasSelectedAlbum = false)
        assertTrue(facts.folderOnly)
        assertFalse(facts.showsGlobalPhotoBlock)
    }

    /** 没有目录来源才维持全局照片权限门控，且只在开关开着时算「停了」。反证：去掉 autoRule 条件，关开关那条红。 */
    @Test
    fun noUsableFolder_keepsGlobalPhotoBlock_onlyWhenRuleIsOn() {
        assertTrue(SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = false, hasSelectedAlbum = true).showsGlobalPhotoBlock)
        assertFalse(SourceAvailability(autoRule = false, photoAccess = MediaAccess.NONE, hasUsableFolder = false, hasSelectedAlbum = true).showsGlobalPhotoBlock)
    }

    /**
     * 目录 + 相册混合、照片权限未完整：文件夹还在传，不算「已停止」，说成相册侧未完整授权。
     * 反证：把混合态算进 showsGlobalPhotoBlock，两条红。
     */
    @Test
    fun mixedScope_showsIncompleteAlbumInsteadOfStopped() {
        val partial = SourceAvailability(autoRule = true, photoAccess = MediaAccess.PARTIAL, hasUsableFolder = true, hasSelectedAlbum = true)
        assertFalse(partial.folderOnly)
        assertFalse(partial.showsGlobalPhotoBlock)
        assertTrue(partial.mixedAlbumIncomplete)
        assertTrue("文件夹还能备份", partial.hasUsableSource)
        val denied = SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = true, hasSelectedAlbum = true)
        assertFalse(denied.showsGlobalPhotoBlock)
        assertTrue(denied.mixedAlbumIncomplete)
        assertFalse("文件夹照常，不说「自动备份没开」", denied.showsDeniedPhotoHint)
        val ruleOff = SourceAvailability(autoRule = false, photoAccess = MediaAccess.NONE, hasUsableFolder = true, hasSelectedAlbum = true)
        assertFalse("规则关着是正常状态，不出状态卡", ruleOff.mixedAlbumIncomplete)
    }

    /** 只有目录时照片权限变差不产生停止状态，来源仍可用。反证：任一条变 false 之外的红。 */
    @Test
    fun folderOnly_keepsNoStopState_forAnyPhotoAccess() {
        for (access in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            val facts = SourceAvailability(autoRule = true, photoAccess = access, hasUsableFolder = true, hasSelectedAlbum = false)
            assertFalse("$access", facts.showsGlobalPhotoBlock)
            assertFalse("$access", facts.mixedAlbumIncomplete)
            assertTrue("$access", facts.hasUsableSource)
        }
    }

    /** 通知侧判定与页面同一份口径：目录可用，或完整授权下已选且存在的相册，才算有可用来源。 */
    @Test
    fun usableSource_factMatchesWhatCanStillBeBackedUp() {
        val folderId = FOLDER_ID_FLAG or 1L
        assertTrue(SourceAvailability.usableSource(selected = setOf(folderId), known = emptySet(), existingFolders = setOf(folderId), existingAlbums = null, photoAccess = MediaAccess.NONE))
        assertTrue("旧版目录没有勾选存值", SourceAvailability.usableSource(selected = null, known = emptySet(), existingFolders = setOf(folderId), existingAlbums = null, photoAccess = MediaAccess.NONE))
        assertFalse("明确取消勾选不是有效目录范围", SourceAvailability.usableSource(selected = emptySet(), known = setOf(folderId), existingFolders = setOf(folderId), existingAlbums = null, photoAccess = MediaAccess.NONE))
        assertTrue(SourceAvailability.usableSource(selected = setOf(7L), known = emptySet(), existingFolders = emptySet(), existingAlbums = setOf(7L), photoAccess = MediaAccess.FULL))
        assertFalse("有限授权：相册不进自动范围", SourceAvailability.usableSource(selected = setOf(7L), known = emptySet(), existingFolders = emptySet(), existingAlbums = setOf(7L), photoAccess = MediaAccess.PARTIAL))
        assertFalse(SourceAvailability.usableSource(selected = emptySet(), known = emptySet(), existingFolders = emptySet(), existingAlbums = null, photoAccess = MediaAccess.FULL))
        assertFalse("已移除的目录不算可用来源（评审）：登记表里只剩未勾选的目录也不行",
            SourceAvailability.usableSource(selected = setOf(folderId), known = setOf(folderId), existingFolders = emptySet(), existingAlbums = null, photoAccess = MediaAccess.NONE))
    }

    /** 有目录来源时不显示相册-only 的提示，也不给「去设置」出口——目录备份仍在继续。 */
    @Test
    fun folderOnly_doesNotShowDeniedPhotoHintOrFullAccessRoute() {
        val folderOnly = SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = true, hasSelectedAlbum = false)
        assertFalse(folderOnly.showsDeniedPhotoHint)
        val partialFolderOnly = SourceAvailability(autoRule = false, photoAccess = MediaAccess.PARTIAL, hasUsableFolder = true, hasSelectedAlbum = false)
        assertFalse(partialFolderOnly.needsFullPhotoAccessSettings)
    }

    /** 相册-only 的旧口径保持：全拒出 denied 提示、部分授权引导去设置申请完整权限。 */
    @Test
    fun albumOnly_keepsLegacyPhotoPermissionRoute() {
        val denied = SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = false, hasSelectedAlbum = true)
        assertTrue(denied.showsDeniedPhotoHint)
        val partial = SourceAvailability(autoRule = false, photoAccess = MediaAccess.PARTIAL, hasUsableFolder = false, hasSelectedAlbum = true)
        assertTrue(partial.needsFullPhotoAccessSettings)
    }

    /**
     * 目录范围与引擎同一份有效范围判据（effectiveBackupScope）：勾选存值里的目录必须在登记表里，
     * 移除过的目录不算可用（评审）；明确取消勾选（空集）不是有效范围。
     */
    @Test
    fun folderScope_derivesFromTheEngineEffectiveScope() {
        val folderId = FOLDER_ID_FLAG or 1L
        assertTrue(SourceAvailability.hasUsableFolder(selected = setOf(folderId), known = emptySet(), existingFolders = setOf(folderId)))
        assertTrue("旧版目录没有新版勾选存值", SourceAvailability.hasUsableFolder(selected = null, known = emptySet(), existingFolders = setOf(folderId)))
        assertFalse("新版明确取消勾选不是有效目录范围", SourceAvailability.hasUsableFolder(selected = emptySet(), known = setOf(folderId), existingFolders = setOf(folderId)))
        assertFalse(SourceAvailability.hasUsableFolder(selected = setOf(7L), known = emptySet(), existingFolders = emptySet()))
    }

    /** 已移除的目录不算可用来源（评审）：范围里残留的旧目录 ID 不再把来源说成可用。 */
    @Test
    fun removedFolder_doesNotCountAsUsableSource() {
        val folderId = FOLDER_ID_FLAG or 1L
        assertFalse("勾选过的目录 A 已从登记表移除：不再算有目录来源",
            SourceAvailability.hasUsableFolder(selected = setOf(folderId), known = setOf(folderId), existingFolders = emptySet()))
        assertTrue("A 还在登记表里就照旧可用",
            SourceAvailability.hasUsableFolder(selected = setOf(folderId), known = setOf(folderId), existingFolders = setOf(folderId)))
    }

    /** 范围读失败与引擎同一份回退（评审）：勾选存值解不出来时，登记目录仍在就还有来源，不误报全停。 */
    @Test
    fun unreadableScope_fallsBackToRegisteredFolders_likeTheEngine() {
        val folderId = FOLDER_ID_FLAG or 1L
        assertTrue("bucket_ids 读不出来（saved=null）、登记表还有目录 A：引擎按登记目录初始化，判定同源",
            SourceAvailability.hasUsableFolder(selected = null, known = setOf(folderId), existingFolders = setOf(folderId)))
        assertFalse("登记表也空了才是真的没有目录来源",
            SourceAvailability.hasUsableFolder(selected = null, known = setOf(folderId), existingFolders = emptySet()))
    }

    /** 空范围（什么都没选）缺的是来源不是权限：不出「照片权限被拒」的停止卡（评审）。 */
    @Test
    fun emptyScope_doesNotShowGlobalPhotoBlock() {
        assertFalse("空范围去设置授权也不会添加来源",
            SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = false, hasSelectedAlbum = false).showsGlobalPhotoBlock)
        assertTrue("已选相册且没有目录来源时照旧报告权限阻断",
            SourceAvailability(autoRule = true, photoAccess = MediaAccess.NONE, hasUsableFolder = false, hasSelectedAlbum = true).showsGlobalPhotoBlock)
    }
}
