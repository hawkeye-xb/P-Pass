// MOB-29: 校准告知的判定 + 「脱离备份开始」的校准内核。
//
// 反证怎么做（验收标准第 4 条）：把 [lostFromLibrary] 的交集条件去掉
// （`missing.filterTo(mutableSetOf()) { it in confirmed }` → `missing.toSet()`），
// 则 [new_photos_never_trigger_the_notice] 与
// [transfer_failed_photos_never_trigger_the_notice] 必须变红——它们喂的
// missing 里全是**没进过 confirmed** 的 hash。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CalibrationTest {

    private fun tempStore(tag: String): ConfirmedStore =
        ConfirmedStore(java.nio.file.Files.createTempDirectory("ppass-calib-$tag").toFile())

    // ── 判定纯函数：谁会被传回来 ────────────────────────────

    @Test
    fun confirmed_and_gone_is_lost() {
        val lost = lostFromLibrary(setOf("a", "b", "c"), listOf("b"))
        assertEquals(setOf("b"), lost)
    }

    @Test
    fun new_photos_never_trigger_the_notice() {
        // 新照片从没拿到过 commit 确认 → 不在 confirmed 里。存储端当然
        // 说「我没有」，但这是「还没传」，不是「客户端丢了」。
        val lost = lostFromLibrary(confirmed = setOf("old1", "old2"), missing = listOf("brand-new"))
        assertTrue("新照片不许触发提示: $lost", lost.isEmpty())
    }

    @Test
    fun transfer_failed_photos_never_trigger_the_notice() {
        // commit 没成功 → recordRun 从没跑过 → 同样不在 confirmed 里。
        val lost = lostFromLibrary(confirmed = emptySet(), missing = listOf("half-sent", "timed-out"))
        assertTrue("传输失败的照片不许触发提示: $lost", lost.isEmpty())
    }

    // ── 校准内核（脱离「备份开始」，只需要一个 exist-check lambda） ──

    @Test
    fun lost_asset_notifies_once_then_never_again() {
        val store = tempStore("once")
        store.recordRun(confirmed = setOf("a", "b"), lastSuccessAt = 1L)
        val notices = mutableListOf<Set<String>>()

        // 第一轮：库里 a 没了。
        val first = runBlocking {
            calibrateConfirmed(store, existCheck = { setOf("a") }, onLost = { notices.add(it) })
        }
        assertTrue("交互成功即算可达", first)
        assertEquals(listOf(setOf("a")), notices)
        // removeMissing 已把 a 剔出确认集——这就是「提示天然一次性」。
        assertEquals(setOf("b"), store.load().confirmed)

        // 第二轮：a 早已不在 confirmed，exist-check 不会再问到它。
        val second = runBlocking {
            calibrateConfirmed(store, existCheck = { emptySet() }, onLost = { notices.add(it) })
        }
        assertTrue(second)
        assertEquals("同一批 hash 不许再提示一次", 1, notices.size)
    }

    @Test
    fun calibration_runs_without_any_backup_starting() {
        // 内核只吃 (store, existCheck, onLost)——没有 WorkManager、没有
        // 前台服务、没有扫描/哈希/上传。这正是「搭背景便车」的前提：
        // 备份一步都没开始也能跑完一次校准。
        val store = tempStore("standalone")
        store.recordRun(confirmed = setOf("x", "y"), lastSuccessAt = 7L)
        var asked: Set<String>? = null
        val ok = runBlocking {
            calibrateConfirmed(store, existCheck = { asked = it; setOf("y") }, onLost = {})
        }
        assertTrue(ok)
        assertEquals("校准问的就是确认集全量", setOf("x", "y"), asked)
        assertEquals(setOf("x"), store.load().confirmed)
        assertEquals("lastSuccessAt 不许被校准动", 7L, store.load().lastSuccessAt)
    }

    @Test
    fun unreachable_daemon_keeps_the_cache_and_stays_silent() {
        val store = tempStore("unreachable")
        store.recordRun(confirmed = setOf("a", "b", "c"), lastSuccessAt = 5L)
        var notified = false
        val ok = runBlocking {
            calibrateConfirmed(
                store,
                existCheck = { throw java.io.IOException("daemon unreachable") },
                onLost = { notified = true },
            )
        }
        assertFalse("不可达 = 无结论", ok)
        assertFalse("不可达不许提示", notified)
        assertEquals(
            "不可达绝不许清零已备份",
            setOf("a", "b", "c"),
            store.load().confirmed,
        )
        assertEquals(3, store.count())
    }

    @Test
    fun empty_cache_is_inconclusive_and_never_asks() {
        val store = tempStore("empty")
        var asked = false
        val ok = runBlocking {
            calibrateConfirmed(store, existCheck = { asked = true; emptySet() }, onLost = {})
        }
        assertFalse(ok)
        assertFalse("没有确认过的照片就不必问", asked)
    }

    @Test
    fun nothing_missing_means_no_notice() {
        val store = tempStore("clean")
        store.recordRun(confirmed = setOf("a"), lastSuccessAt = 1L)
        var notified = false
        val ok = runBlocking {
            calibrateConfirmed(store, existCheck = { emptySet() }, onLost = { notified = true })
        }
        assertTrue(ok)
        assertFalse(notified)
        assertEquals(setOf("a"), store.load().confirmed)
    }

    @Test
    fun notice_fires_before_the_cache_is_pruned() {
        // 顺序是承重的：先算 lost 再 removeMissing。反过来交集恒空，
        // 提示永远发不出去。这里断言 onLost 看到的是**校准前**的口径。
        val store = tempStore("order")
        store.recordRun(confirmed = setOf("a", "b"), lastSuccessAt = 1L)
        var seenWhileNotifying: Set<String> = emptySet()
        runBlocking {
            calibrateConfirmed(
                store,
                existCheck = { setOf("a", "b") },
                onLost = { seenWhileNotifying = store.load().confirmed },
            )
        }
        assertEquals(setOf("a", "b"), seenWhileNotifying)
        assertTrue(store.load().confirmed.isEmpty())
    }

    // ── 字典 key 与文案（用户定稿那句话不许被改写） ──────────────

    @Test
    fun notice_copy_comes_from_the_shared_dictionary() {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "assets/i18n").isDirectory) {
            dir = dir.parentFile ?: error("assets/i18n not found")
        }
        val zh = File(dir, "assets/i18n/zh.json").readText()
        assertEquals(
            "资源在客户端丢失，正在重传",
            com.hawkeyexb.ppass.i18n.DiagText.resolveFromJson(zh, MSG_REUPLOAD_TITLE),
        )
        assertEquals(
            "如果是主动删除，请先删除移动端的数据。",
            com.hawkeyexb.ppass.i18n.DiagText.resolveFromJson(zh, MSG_REUPLOAD_BODY),
        )
    }
}
