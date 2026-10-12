// #836：「已选相册」只有一个口径——已选且当前存在。设置页计数与相册列表必须对得上：
// 被选的相册文件夹删掉后，存储里的 id 还在（同路径重建后可继续备份），但不再计入「N 个相册」。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SCOPE836SelectedExistingCountTest {

    /** 反证：直接用已选 id 的个数（旧口径）→ 第一条红：三星现场「1 个相册」但列表里一个没勾。 */
    @Test
    fun aDeletedAlbumNoLongerCounts() {
        assertEquals(0, selectedExistingCount(selected = setOf(42L), existing = setOf(1L, 2L)))
        assertNull("0 个 = 显示「未选相册」", backupScopeRowCount(selectedExistingCount(setOf(42L), setOf(1L, 2L))))
    }

    @Test
    fun onlyExistingSelectedAlbumsCount() {
        assertEquals(2, selectedExistingCount(selected = setOf(1L, 2L, 42L), existing = setOf(1L, 2L, 3L)))
    }

    @Test
    fun neverSavedStaysNull() {
        assertNull(selectedExistingCount(selected = null, existing = setOf(1L)))
    }

    /** 读不到相册（没有照片权限）时无从判断哪些还在：沿用已选个数，不把范围显示成空。 */
    @Test
    fun unknownExistingFallsBackToTheSavedCount() {
        assertEquals(3, selectedExistingCount(selected = setOf(1L, 2L, 42L), existing = null))
    }
}

class SCOPE836RecountOnResumeTest {
    private val main = java.io.File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    /**
     * 相册是在 App 外面删的（相册 App / 文件管理器），用户切回来时 composition 还活着——只在进入首页
     * 时算一次，计数就停在旧值（三星 test.9 实测：删掉已选相册后切回仍显示「2 个相册」，冷启动才变 1）。
     * 反证：计数的 LaunchedEffect 不以「回到前台」为键，或 ON_RESUME 不推进它 → 红。
     */
    @Test
    fun theCountIsRecomputedEveryTimeTheAppComesBack() {
        val effect = main.substringAfter("selectedBucketCount by remember").substringBefore("selectedExistingCount(")
        assertTrue("计数要以回到前台为键: $effect", effect.contains("LaunchedEffect(mediaAccess, resumeCount)"))
        val onResume = main.substringAfter("Lifecycle.Event.ON_RESUME ->").substringBefore("Lifecycle.Event.ON_STOP")
        assertTrue("ON_RESUME 要推进 resumeCount", onResume.contains("resumeCount++"))
    }
}
