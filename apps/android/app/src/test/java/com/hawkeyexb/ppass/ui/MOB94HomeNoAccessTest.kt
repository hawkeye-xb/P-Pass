// MOB-94: 首页在拿不到相册时不许说「照片都存好了」。
//
// HomeScreen 是 Compose，本仓没有 Robolectric，所以这里测的是两件能测的
// 事：① 渲染分支的判据（纯函数 shouldShowWifiDeferredHint 同一口径）；
// ② 源文本门禁——绿卡分支必须被非 FULL 挡在外面，且两档文案不共用。
//
// ②是源文本，只能证明写法，证明不了效果；判据本身由 MOB94MediaAccessTest
// 的真行为测试守着。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB94HomeNoAccessTest {

    private fun homeScreen() =
        File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()

    @Test
    fun the_waiting_hint_is_suppressed_whenever_the_library_is_not_fully_readable() {
        // 拿不到完整相册时 N/M 是假数，"将在连上 Wi-Fi 后进行"也就无从谈起。
        assertTrue(
            shouldShowWifiDeferredHint(
                wifiOnly = true, wifiDeferred = true, busy = false,
                mediaAccess = MediaAccess.FULL,
            ),
        )
        for (blocked in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            assertFalse(
                "拿不到完整相册（$blocked）时不许显示排队提示",
                shouldShowWifiDeferredHint(
                    wifiOnly = true, wifiDeferred = true, busy = false,
                    mediaAccess = blocked,
                ),
            )
        }
    }

    @Test
    fun the_hero_card_is_gated_on_full_access_not_on_partial_alone() {
        val source = homeScreen()

        assertTrue(
            "hero 卡的判据必须是「不是 FULL」——只看 partial 会把全拒放进正常分支，那正是本卡的 bug",
            source.contains("if (mediaAccess != MediaAccess.FULL)"),
        )
        assertFalse(
            "不许再留布尔 partialAccess 参数——两档互斥，布尔并列表示不了",
            source.contains("partialAccess: Boolean"),
        )
    }

    @Test
    fun the_two_blocked_tiers_do_not_share_one_string() {
        val source = homeScreen()

        assertTrue("全拒要有自己的标题", source.contains("R.string.no_media_access_title"))
        assertTrue("全拒要有自己的正文", source.contains("R.string.no_media_access_body"))
        assertTrue("部分授权的文案保留", source.contains("R.string.partial_access_title"))

        for (loc in listOf("values", "values-zh")) {
            val strings = File("src/main/res/$loc/strings.xml").readText()
            assertTrue("$loc 缺 no_media_access_title", strings.contains("\"no_media_access_title\""))
            assertTrue("$loc 缺 no_media_access_body", strings.contains("\"no_media_access_body\""))
        }
    }
}
