// MOB-37: 提示优先级的骨架（给 UI-04 留的接口）。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeNoticesTest {

    private fun notice(kind: HomeNoticeKind) = HomeNotice(kind, body = kind.name)

    @Test
    fun no_notices_means_nothing_to_show() {
        assertNull(topNotice(emptyList()))
    }

    @Test
    fun the_most_urgent_notice_wins() {
        // UI-04 的场景：重启后「后台进程有问题」与「去授权」同时成立。
        val top = topNotice(
            listOf(
                notice(HomeNoticeKind.NOTIFICATION_PERMISSION),
                notice(HomeNoticeKind.BACKUP_INTERRUPTED),
                notice(HomeNoticeKind.REUPLOAD),
            )
        )
        assertEquals(HomeNoticeKind.BACKUP_INTERRUPTED, top?.kind)
    }

    @Test
    fun reupload_is_the_least_urgent_of_the_ranked_kinds() {
        // 补充信息类：照片已经在传回来了，用户不动手也没事。排序是提案，
        // UI-04 可以重排——但它绝不该盖住「备份停了」这类阻塞态。
        assertEquals(HOME_NOTICE_PRIORITY.size - 1, HOME_NOTICE_PRIORITY.indexOf(HomeNoticeKind.REUPLOAD))
        val top = topNotice(listOf(notice(HomeNoticeKind.REUPLOAD), notice(HomeNoticeKind.PAIRING_LOST)))
        assertEquals(HomeNoticeKind.PAIRING_LOST, top?.kind)
    }

    @Test
    fun every_kind_is_ranked_exactly_once() {
        // 漏登记一个类别 = 它悄悄排到末位。新增提示时这条立刻红。
        assertEquals(HomeNoticeKind.entries.size, HOME_NOTICE_PRIORITY.size)
        assertEquals(HOME_NOTICE_PRIORITY.size, HOME_NOTICE_PRIORITY.toSet().size)
    }

    @Test
    fun a_single_notice_is_shown_as_is() {
        val only = notice(HomeNoticeKind.REUPLOAD)
        assertEquals(only, topNotice(listOf(only)))
    }
}
