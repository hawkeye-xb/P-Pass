// #541（UI-23，2026-09-29 夜间回归，0.6.1-test.2 模拟器）：
//
// ① 媒体权限「无 → 全部」之后，首页英雄卡停在 `0 / 0`，回前台不刷新，`am kill` 重开才恢复 7 / 7。
//    根因：BackupUiStateHolder 把 n（范围内 MediaStore 计数）缓存在 inScopeTotal 里，只在 init 与 ContentObserver
//    回调时重数。无权限时数出来是 0（查询返回空，不抛异常，所以不是「读不到」而是 0 / 0）；授权既不触发
//    ContentObserver，也不杀进程（撤销才杀——所以 am kill / 撤销后重开都「修好了」）；MainActivity 在 ON_RESUME
//    重读了 mediaAccess，却从来没交给 holder。
// ② 0 张照片走完 onboarding 后，设置行显示「All albums」，实际一张都不备份。
//    根因：设置行把「范围从未保存（null）」渲染成「全部相册」——MOB-40 之前「没选过 = 全量」的旧语义；
//    引擎早已把 null 与空集都当成「一张都不在范围内」。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.flow.EngineView
import com.hawkeyexb.ppass.backup.flow.FlowProjection
import com.hawkeyexb.ppass.backup.flow.GlobalState
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.flowTripletOf
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.backupScopeRowCount
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UI23AccessRecountAndScopeRowTest {

    // ── ① 档位变化判据 ─────────────────────────────────────────────

    @Test
    fun first_access_is_only_recorded_not_a_change() {
        // init 已经数过一次 n；首次进入组合时的那次上报不该再重数。
        assertFalse(MediaAccessRecountGate().onAccess(MediaAccess.NONE))
    }

    @Test
    fun none_to_full_is_a_change_and_same_tier_is_not() {
        val gate = MediaAccessRecountGate()
        gate.onAccess(MediaAccess.NONE)
        assertTrue("无 → 全部必须重数 n", gate.onAccess(MediaAccess.FULL))
        assertFalse("每次 ON_RESUME 都报同一档，不该每次都重数", gate.onAccess(MediaAccess.FULL))
        assertTrue(gate.onAccess(MediaAccess.PARTIAL))
        assertTrue(gate.onAccess(MediaAccess.NONE))
    }

    @Test
    fun recounted_n_is_what_the_triplet_shows() {
        // 回归现场：n 缓存是 0 → 0 / 0；重数成 7 之后三元组如实给 7。
        val stale = FlowProjection(view = EngineView(GlobalState.IDLE, pending = 0), confirmed = 7, inScopeTotal = 0L, failed = 0)
        assertEquals(0L, flowTripletOf(stale, setOf(1L))?.n)
        assertEquals(7L, flowTripletOf(stale.copy(inScopeTotal = 7L), setOf(1L))?.n)
    }

    // ── ① 档位刚变时暂扣旧视图（#401 的「先说都存好了」不许借这条路回来）──────────

    @Test
    fun stale_engine_view_after_access_change_is_held_until_the_engine_emits_again() {
        // 无权限时引擎算出的待办是 0；授权后 n 重数成 7，但引擎还没重算。
        val staleView = EngineView(GlobalState.IDLE, pending = 0)
        val gate = MediaAccessRecountGate()
        gate.onAccess(MediaAccess.NONE)
        gate.onAccess(MediaAccess.FULL)

        // 不暂扣：m = 7 − 0 = 7，「照片都存好了」——而实际只确认过 3 张。
        val unguarded = FlowProjection(view = staleView, confirmed = 3, inScopeTotal = 7L, failed = 0)
        assertTrue(backupUiStateOf(unguarded) is BackupUiState.AllSafe)

        // 暂扣：视图按 null 投影，m 退回 order 表的已确认 3，不说「都存好了」。
        val guarded = unguarded.copy(view = gate.visible(staleView))
        assertNull(guarded.view)
        assertEquals(3L, guarded.done)
        assertFalse(backupUiStateOf(guarded) is BackupUiState.AllSafe)

        // 引擎发出下一个视图 → 放行。
        gate.onEngineView()
        val fresh = EngineView(GlobalState.IDLE, pending = 4)
        assertEquals(fresh, gate.visible(fresh))
    }

    @Test
    fun no_access_change_means_the_view_passes_through() {
        val gate = MediaAccessRecountGate()
        gate.onAccess(MediaAccess.FULL)
        gate.onAccess(MediaAccess.FULL)
        val v = EngineView(GlobalState.IDLE, pending = 2)
        assertEquals(v, gate.visible(v))
    }

    // ── ① 接线（真正漏掉的是这一下）──────────────────────────────

    @Test
    fun home_hands_media_access_changes_to_the_holder() {
        val home = sliceBetween(code("MainActivity.kt"), "BackupUiStateHolder(context, client, identity, s.pairing)", "is Screen.Buckets ->")
        assertTrue(
            "首页必须以 mediaAccess 为键把档位交给 holder——ON_RESUME 只改了 composable 状态，holder 的 n 不会重数",
            Regex("""LaunchedEffect\(holder, mediaAccess\)\s*\{\s*holder\.onMediaAccess\(mediaAccess\)""").containsMatchIn(home),
        )
    }

    @Test
    fun holder_drops_the_cached_n_and_recounts_on_access_change() {
        val body = sliceBetween(code("backup/BackupUiStateHolder.kt"), "fun onMediaAccess(", "fun dispose()")
        assertTrue("档位变了要清 n 的缓存", body.contains("inScopeTotal = null"))
        assertTrue("档位变了要叫醒引擎重算待办", body.contains("gateway?.onMediaChanged()"))
        assertTrue("档位变了要立刻重读账目", body.contains("refresh(recount = true)"))
    }

    // ── ② 设置行文案与引擎范围同源 ────────────────────────────────

    @Test
    fun never_saved_or_empty_scope_reads_as_none_selected() {
        assertNull("范围从未保存 = 一张都不备，不是「全部相册」", backupScopeRowCount(null))
        assertNull("保存了空集（0 张时点了开始）同样是「未选相册」，不说「0 个相册」", backupScopeRowCount(0))
        assertEquals(2, backupScopeRowCount(2))
    }

    @Test
    fun the_all_albums_wording_is_gone() {
        assertFalse(code("ui/HomeScreen.kt").contains("backup_scope_all"))
        assertTrue(code("ui/HomeScreen.kt").contains("R.string.backup_scope_none"))
    }

    // ── helpers（剥注释行，同 ForegroundCatchupOnResumeTest）─────────────

    private fun code(rel: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel")
            .readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    private fun sliceBetween(s: String, from: String, to: String): String {
        assertTrue("源码锚点已消失，断言失效：$from", s.contains(from))
        val tail = s.substringAfter(from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }
}
