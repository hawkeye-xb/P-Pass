// MOB-92（2026-09-20 验收人真机）：
//
//   macOS 选 7 个相册 → 断开 → 连 Windows 选 2 个 → 断开 → 连回 macOS
//
// 回到 macOS 拿到的是给 Windows 选的那 2 个。验收人原话：
//
// > 这对应不上吧？这账本有问题吧，不是说好了这些信息状态保留吗？
//
// 根因：交付账本按桌面分（files/flow-state/<daemonNodeId>/），范围不分
// ——一个写死的全局 `backup_scope`。而 MOB-87 新增的「连回旧电脑就直接
// 回首页」看到「范围非空」就放行，于是用户连重选的机会都没有，**静默用着
// 错的范围开始备份**。
//
// 本仓没有 Robolectric，SharedPreferences 在 JVM 侧跑不起来，所以判据提成
// 纯函数在这里钉边界（同 flowReuploadNoticeCount / externalDeleteNotice 的
// 惯例），接线由 MOB92ScopeWiringTest 的源文本门禁守。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.BackupScopeStore.Companion.Adoption
import com.hawkeyexb.ppass.backup.BackupScopeStore.Companion.decideAdoption
import com.hawkeyexb.ppass.backup.BackupScopeStore.Companion.scopePrefsName
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class MOB92PerDesktopScopeTest {
    private val mac = "9b1ae9185d69134741b7e2f85bde4aa54e1700404b26ae8184dc46da5a54a657"
    private val win = "4e8b6142145ce95246cb89418448e925500edfd4da65651218acdefd7edb52ee"

    @Test
    fun two_desktops_never_share_one_scope_file() {
        assertNotEquals(
            "两台桌面共用一份范围，就是本卡的原始 bug",
            scopePrefsName(mac),
            scopePrefsName(win),
        )
        // 切过去再切回来，名字必须稳定——否则「回到 macOS 恢复 7 个相册」
        // 无从谈起。
        assertEquals(scopePrefsName(mac), scopePrefsName(mac))
    }

    @Test
    fun an_unpaired_phone_falls_back_to_the_legacy_global_file() {
        // 未配对时没有「哪台桌面」可言；这也正是迁移要读的那一份。
        assertEquals(BackupScopeStore.LEGACY_PREFS, scopePrefsName(null))
        assertEquals(BackupScopeStore.LEGACY_PREFS, scopePrefsName(""))
        assertEquals(BackupScopeStore.LEGACY_PREFS, scopePrefsName("   "))
    }

    @Test
    fun the_first_desktop_to_ask_adopts_the_legacy_scope() {
        // 升级时用户手上就一份范围，它属于当时配对着的那台。
        assertEquals(
            Adoption.COPY_THEN_STAMP,
            decideAdoption(alreadyAdoptedBy = null, legacyBuckets = "11,22,33"),
        )
    }

    @Test
    fun a_second_desktop_must_not_inherit_it() {
        // 不止认领一次的话，之后连上的每一台新桌面都会继承这份范围——
        // **等于把 bug 换了个形状**：不再是「切回去丢了」，而是「新电脑
        // 莫名其妙已经替你选好了相册」。
        assertEquals(
            Adoption.ALREADY_CLAIMED,
            decideAdoption(alreadyAdoptedBy = mac, legacyBuckets = "11,22,33"),
        )
    }

    @Test
    fun an_empty_legacy_scope_still_gets_stamped() {
        // 从没选过范围——没东西可迁，但也要盖章。不盖的话，第一台桌面之后
        // 存进来的范围会被下一台当成「历史遗留」继承走。
        assertEquals(Adoption.STAMP_ONLY, decideAdoption(null, null))
        assertEquals(Adoption.STAMP_ONLY, decideAdoption(null, ""))
    }

    @Test
    fun the_stamp_is_what_makes_adoption_idempotent() {
        // 认领一次之后，无论老的那份还有什么内容，结局都不再变。
        for (buckets in listOf(null, "", "1", "1,2,3")) {
            assertEquals(
                "盖过章就不该再动",
                Adoption.ALREADY_CLAIMED,
                decideAdoption(alreadyAdoptedBy = win, legacyBuckets = buckets),
            )
        }
    }
}
