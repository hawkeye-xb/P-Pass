package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1886：范围页两个时间胶囊在 1.5× 大字体下的布局——JVM 单测钉住两条决定（都是读源码的
 * 结构性断言，与 UI08BucketScreenTest 同款）。
 *
 * 1. 胶囊高度只有「最小高度」、没有固定高度：写死 `Modifier.height(36.dp)` 时，英文 1.5× 下
 *    标签换行后第二行被底边裁掉，视觉只剩「Incl」。改成 `heightIn(min = 36.dp)` 让胶囊自己长高。
 * 2. 两个胶囊的容器是可换行的 `FlowRow`：普通 `Row` 里第二个胶囊只吃第一个剩下的宽度，英文
 *    1.5× 时只剩 145px（51.5dp）被硬裁；`FlowRow` 放不下时第二个整体落到下一行、各自保持宽度。
 *
 * 触控区不靠这个高度撑：Material 3 `FilterChip` 自带的 `minimumInteractiveComponentSize`
 * 已把可点区撑到 48dp（真机实测 135px）。
 */
class ScopeTimeChipLayoutTest {

    private fun source(rel: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/$rel").readText()
    }

    /** 反证：把 `heightIn(min = 36.dp)` 改回 `Modifier.height(36.dp)` 本条即红。 */
    @Test
    fun chip_height_is_a_minimum_not_a_fixed_height() {
        val photos = source("PhotosScreen.kt")
        assertTrue("胶囊必须只有最小高度", photos.contains("heightIn(min = 36.dp)"))
        assertFalse("写死固定高度会让换行后的标签被裁掉", photos.contains("Modifier.height(36.dp)"))
    }

    /** 反证：把两个胶囊放回普通 `Row` 本条即红。 */
    @Test
    fun the_two_time_chips_are_laid_out_in_a_wrapping_container() {
        val bucket = source("BucketScreen.kt")
        assertTrue("两个时间胶囊必须放进可换行的 FlowRow", bucket.contains("FlowRow("))
        assertFalse(
            "普通 Row 里第二个胶囊只吃剩余宽度，会被挤窄硬裁",
            bucket.contains("Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp))"),
        )
        val flowBlock = bucket.substringAfter("FlowRow(").substringBefore("Spacer(Modifier.height(14.dp))")
        assertTrue("第一个时间胶囊要在 FlowRow 里", flowBlock.contains("PhotoFilterChip(sinceLabel"))
        assertTrue(
            "第二个时间胶囊要在 FlowRow 里",
            flowBlock.contains("PhotoFilterChip(stringResource(R.string.scope_time_all)"),
        )
    }
}
