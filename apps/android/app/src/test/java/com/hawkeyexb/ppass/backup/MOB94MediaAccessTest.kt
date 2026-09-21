// MOB-94: 相册权限被全部关掉时，首页显示「0 / 0 张已回家 · 照片都存好了」。
//
// 真机实测 2026-09-21（0.5.6-test.3 / SM-S9210）：pm revoke 掉
// READ_MEDIA_IMAGES / READ_MEDIA_VIDEO / READ_MEDIA_VISUAL_USER_SELECTED
// 之后启动 App，首屏就是那句绿卡。没有任何提示，也没有任何地方能把
// 权限要回来——一张也扫不到，却盖了个「都存好了」的章。
//
// MOB-02 §二做了「只给了部分照片」那一档，**全拒这一档没人管**：两个
// 权限都没给时 isPartialMediaAccess 返回 false，于是落进「正常」分支。
package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Test

class MOB94MediaAccessTest {

    private companion object {
        const val SDK_34 = 34
        const val SDK_33 = 33
        const val SDK_26 = 26
    }

    // ── 三档各归各位 ────────────────────────────────────────────
    @Test
    fun full_access_is_decided_by_the_primary_permission_alone() {
        // imagesGranted 本身就是完整授权的充分条件——visualSelected 是否
        // 历史遗留无关（理由见 isPartialMediaAccess 上面那段真机反证）。
        assertEquals(
            MediaAccess.FULL,
            mediaAccessOf(imagesGranted = true, visualSelectedGranted = false, sdkInt = SDK_34),
        )
        assertEquals(
            MediaAccess.FULL,
            mediaAccessOf(imagesGranted = true, visualSelectedGranted = true, sdkInt = SDK_34),
        )
    }

    @Test
    fun only_selected_photos_is_partial() {
        assertEquals(
            MediaAccess.PARTIAL,
            mediaAccessOf(imagesGranted = false, visualSelectedGranted = true, sdkInt = SDK_34),
        )
    }

    /** 本卡的核心：两个都没给 = NONE，不是"正常"。 */
    @Test
    fun nothing_granted_is_none_not_normal() {
        assertEquals(
            MediaAccess.NONE,
            mediaAccessOf(imagesGranted = false, visualSelectedGranted = false, sdkInt = SDK_34),
        )
    }

    @Test
    fun below_api_34_there_is_no_partial_tier_only_full_or_none() {
        // READ_MEDIA_VISUAL_USER_SELECTED 在 34 以下不存在，所以只有两档。
        assertEquals(
            MediaAccess.NONE,
            mediaAccessOf(imagesGranted = false, visualSelectedGranted = true, sdkInt = SDK_33),
        )
        assertEquals(
            MediaAccess.FULL,
            mediaAccessOf(imagesGranted = true, visualSelectedGranted = false, sdkInt = SDK_26),
        )
        assertEquals(
            MediaAccess.NONE,
            mediaAccessOf(imagesGranted = false, visualSelectedGranted = false, sdkInt = SDK_26),
        )
    }

    // ── 与 MOB-02 的既有判定保持一致，不许互相打架 ───────────────
    @Test
    fun the_partial_tier_still_agrees_with_the_mob02_predicate() {
        for (images in listOf(true, false)) {
            for (visual in listOf(true, false)) {
                for (sdk in listOf(SDK_26, SDK_33, SDK_34)) {
                    val viaEnum = mediaAccessOf(images, visual, sdk) == MediaAccess.PARTIAL
                    val viaPredicate = isPartialMediaAccess(images, visual, sdk)
                    assertEquals(
                        "images=$images visual=$visual sdk=$sdk 两个判定必须同口径",
                        viaPredicate,
                        viaEnum,
                    )
                }
            }
        }
    }
}
