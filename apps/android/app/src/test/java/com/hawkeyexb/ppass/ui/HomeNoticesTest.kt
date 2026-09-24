// MOB-37: 提示优先级的骨架（给 UI-04 留的接口）。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
                notice(HomeNoticeKind.SOURCE_MISSING),
                notice(HomeNoticeKind.BACKUP_INTERRUPTED),
                notice(HomeNoticeKind.PARTIAL_ACCESS),
            )
        )
        assertEquals(HomeNoticeKind.BACKUP_INTERRUPTED, top?.kind)
    }

    @Test
    fun source_missing_is_the_least_urgent_of_the_ranked_kinds() {
        // 补充信息类（#418 删掉 REUPLOAD 之后，它是末位）：用户不动手也没事。
        // 排序是提案，但它绝不该盖住「备份停了」这类阻塞态。
        assertEquals(HOME_NOTICE_PRIORITY.size - 1, HOME_NOTICE_PRIORITY.indexOf(HomeNoticeKind.SOURCE_MISSING))
        val top = topNotice(listOf(notice(HomeNoticeKind.SOURCE_MISSING), notice(HomeNoticeKind.PAIRING_LOST)))
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
        val only = notice(HomeNoticeKind.SOURCE_MISSING)
        assertEquals(only, topNotice(listOf(only)))
    }

    @Test
    fun priority_selection_is_not_list_order() {
        // 负向证明：候选按「优先级从低到高」排列（SOURCE_MISSING 在最前），
        // 若 topNotice 只是「取第一条」而非按 HOME_NOTICE_PRIORITY 挑，
        // 这条断言会失败——它锁死的是「选择行为」，不是「列表顺序」。
        val candidates = listOf(
            notice(HomeNoticeKind.SOURCE_MISSING),
            notice(HomeNoticeKind.PARTIAL_ACCESS),
            notice(HomeNoticeKind.BACKUP_INTERRUPTED),
        )
        assertEquals(HomeNoticeKind.BACKUP_INTERRUPTED, topNotice(candidates)?.kind)
        // 反证：若实现退化成 firstOrNull，会拿到 SOURCE_MISSING（最低优先级）。
        assertNotEquals(HomeNoticeKind.SOURCE_MISSING, topNotice(candidates)?.kind)
    }

    // UI-12: HomeNotice 新增字段的默认值与语义——不引入运行时依赖，
    // 纯数据类可以直接在 JVM 测试里断言，不需要 stringResource/Compose。
    @Test
    fun a_notice_is_not_critical_and_has_no_dismiss_by_default() {
        val n = notice(HomeNoticeKind.SOURCE_MISSING)
        assertTrue("default critical must be false", !n.critical)
        assertNull("default dismissLabel must be null (no dismiss action)", n.dismissLabel)
    }

    @Test
    fun a_notice_can_carry_a_separate_dismiss_action_from_its_primary_action() {
        var dismissed = false
        var resolved = false
        val n = HomeNotice(
            kind = HomeNoticeKind.BACKUP_INTERRUPTED,
            body = "body",
            actionLabel = "去处理",
            onAction = { resolved = true },
            dismissLabel = "知道了",
            onDismiss = { dismissed = true },
        )
        n.onAction()
        n.onDismiss()
        assertTrue("primary action must fire independently of dismiss", resolved)
        assertTrue("dismiss action must fire independently of primary", dismissed)
    }
}
