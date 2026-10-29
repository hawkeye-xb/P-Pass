package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1259：系统照片权限框之前必须先过一屏说明。
 * 权限链只在 MainActivity 里接线（本仓没有 Robolectric），这里按源码形状钉住三件事：
 * 缺权限 → 进说明屏、不直接弹；系统框只从说明屏的「继续」弹出；已授权的路径不经过说明屏。
 */
class PhotoAccessIntroRouteTest {
    private val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
    private val res = File("src/main/res").let { r ->
        listOf("values", "values-zh").associateWith { File(r, "$it/strings.xml").readText() }
    }

    @Test
    fun missing_permission_goes_to_the_intro_screen_first() {
        val picker = main.substringAfter("fun enterBucketPicker(").substringBefore("\n    }\n")
        assertTrue(picker.contains("needed.isNotEmpty() -> screen = Screen.PhotoIntro(pairing, firstTime)"))
        assertFalse("缺权限时不许跳过说明屏直接弹系统框", picker.contains("bucketMediaPermission.launch"))
        assertTrue("已授权直接进选相册，不经过说明屏", picker.contains("else -> screen = Screen.Buckets("))
    }

    @Test
    fun the_system_prompt_is_only_launched_from_continue() {
        assertEquals(1, Regex("bucketMediaPermission\\.launch\\(").findAll(main).count())
        val intro = main.substringAfter("is Screen.PhotoIntro -> PhotoAccessIntroScreen(").substringBefore("is Screen.Trouble ->")
        assertTrue(intro.contains("onContinue = {"))
        assertTrue(intro.contains("bucketMediaPermission.launch(withMediaLocation(needed))"))
    }

    @Test
    fun update_dialog_does_not_cover_the_intro() {
        assertTrue(main.contains("screen !is Screen.PhotoIntro"))
    }

    @Test
    fun copy_exists_in_both_languages_and_names_the_computer() {
        val keys = listOf("photo_intro_title", "photo_intro_where", "photo_intro_full", "photo_intro_choose", "photo_intro_stop", "photo_intro_continue")
        for ((dir, xml) in res) for (k in keys) assertTrue("$dir 缺 $k", xml.contains("name=\"$k\""))
        for ((dir, xml) in res) assertTrue("$dir：第 1 条要带电脑名", Regex("name=\"photo_intro_where\">[^<]*%1\\\$s").containsMatchIn(xml))
        // 中继服务器只转发不存储——能说「不存任何云端」，不能说「不经过任何服务器」（卡面第 1 条）。
        for ((_, xml) in res) assertFalse(Regex("name=\"photo_intro_[a-z]+\">[^<]*(不经过任何服务器|any server)").containsMatchIn(xml))
        for ((_, xml) in res) assertFalse("这一屏不提通知（#1262）", Regex("name=\"photo_intro_[a-z]+\">[^<]*(通知|notif)").containsMatchIn(xml))
    }
}
