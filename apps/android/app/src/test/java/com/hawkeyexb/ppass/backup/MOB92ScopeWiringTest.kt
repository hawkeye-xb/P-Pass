// MOB-92 的接线门禁。判据本身在 MOB92PerDesktopScopeTest 里钉，这里只守
// 「生产代码真的按桌面问范围」——本仓没有 Robolectric，SharedPreferences
// 的实际读写在 JVM 侧跑不起来，而这条链的失效方式恰恰是「有人重构时
// 又把 nodeId 丢了」，源文本正好能钉住（同 ForegroundCatchupOnResumeTest
// 的做法）。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB92ScopeWiringTest {
    private fun code(relative: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/$relative").readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    @Test
    fun the_scope_file_is_keyed_by_the_paired_desktop() {
        val store = code("app/src/main/java/com/hawkeyexb/ppass/backup/BackupScopeStore.kt")
        // 构造时必须能拿到 nodeId：显式传，或自己从 pairing.json 读。
        assertTrue("要么显式传 nodeId", store.contains("daemonNodeId: String? = null"))
        assertTrue("要么自己读当前配对", store.contains("PairingStore(appContext.filesDir).load()?.daemonNodeId"))
        // prefs 名必须过 scopePrefsName——绕过它就等于又写死一个全局名字。
        assertTrue(
            "prefs 名只许由 scopePrefsName 决定",
            store.contains("getSharedPreferences(scopePrefsName(id)"),
        )
    }

    @Test
    fun repairing_asks_this_desktop_for_its_own_scope() {
        // 本卡最要紧的一处：MOB-87 的「连回旧电脑直接回首页」如果读全局范围，
        // 「macOS → Windows → 回 macOS」时它非空（是 Windows 的 2 个），
        // 于是直接放行、静默用着错的范围开始备份。
        val main = code("app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt")
        val predicate = main.substringAfter("fun hasExistingLedgerFor(").substringBefore("\n\n")
        assertTrue(
            "重连判据必须按这台桌面问范围",
            predicate.contains("BackupScopeStore(context, pairing.daemonNodeId)"),
        )
        assertFalse(
            "不许再读全局那一份",
            predicate.contains("BackupScopeStore(context)"),
        )
    }
}
