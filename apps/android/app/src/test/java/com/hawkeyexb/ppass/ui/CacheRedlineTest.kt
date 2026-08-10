// MOB-04 缓存红线守卫——①失效联动逐出决策（纯函数）②全工程无磁盘 thumb
// 缓存（源码扫描 grep 守卫）③红线注释在位。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CacheRedlineTest {

    // ── 红线①：timeline 结果集缩小 → 逐出对应条目 ──

    @Test
    fun staleThumbKeys_evictsHashesNotInCurrentSet() {
        val keys = listOf("aaa/256", "aaa/1024", "bbb/256", "ccc/256")
        // 结果集只剩 aaa（bbb/ccc 被 SYNC-01 对账删除）——bbb/ccc 逐出，
        // aaa 的不同尺寸 key 全部保留。
        assertEquals(
            listOf("bbb/256", "ccc/256"),
            staleThumbKeys(keys, setOf("aaa")),
        )
    }

    @Test
    fun staleThumbKeys_keepsAllSizesForKnownHashes() {
        assertEquals(
            emptyList<String>(),
            staleThumbKeys(listOf("aaa/256", "aaa/1024", "aaa/512"), setOf("aaa")),
        )
    }

    @Test
    fun staleThumbKeys_emptyCurrentSetEvictsEverything() {
        val keys = listOf("aaa/256", "bbb/1024")
        assertEquals(keys, staleThumbKeys(keys, emptySet()))
    }

    @Test
    fun staleThumbKeys_emptyKeysNoop() {
        assertEquals(emptyList<String>(), staleThumbKeys(emptyList(), setOf("aaa")))
    }

    // ── 红线②：全工程无磁盘 thumb 缓存（源码 grep 守卫） ──

    @Test
    fun noDiskThumbCacheInSources() {
        // gradle Test workingDir = :app 模块目录（apps/android/app）。
        val root = File("src/main")
        if (!root.isDirectory) throw AssertionError(
            "测试工作目录找不到源码根（应为 apps/android/app）：" + File(".").absolutePath
        )
        val ktFiles = root.walkTopDown().filter { it.isFile && it.name.endsWith(".kt") }.toList()
        assertTrue("找不到 Kotlin 源码", ktFiles.isNotEmpty())

        // 危险模式 = thumb 与文件系统落盘字样出现在同一语句（300 字符窗口）
        // ——缩略图缓存只允许内存 LruCache。已知合法例外：confirmedHashesUnder
        // 读 backup-state（确认缓存 hash 集合，与缩略图无关）在窗口外。
        val diskHints = listOf("filesDir", "cacheDir", "externalCacheDir", ".thumb", "thumbCacheDir")
        val violations = ktFiles.filter { f ->
            val text = f.readText()
            val idx = text.indexOf("thumb", ignoreCase = true)
            idx >= 0 && diskHints.any { h ->
                val hi = text.indexOf(h)
                hi >= 0 && kotlin.math.abs(hi - idx) < 300
            }
        }
        assertTrue(
            "发现疑似磁盘 thumb 缓存实现：${violations.joinToString { it.path }}",
            violations.isEmpty(),
        )

        // LruCache 声明必须只有 PhotosScreen.kt 一处（唯一内存缓存）。
        val lruDecl = ktFiles.filter {
            it.readText().contains("LruCache<")
        }
        assertEquals(
            "LruCache 声明只能有一处（PhotosScreen.kt 的内存缩略图缓存）",
            listOf("PhotosScreen.kt"),
            lruDecl.map { it.name },
        )
    }

    // ── 红线注释在位 ──

    @Test
    fun redlineCommentsInPlace() {
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt")
        val text = photos.readText()
        // 红线①：失效联动注释
        assertTrue("缺少红线①注释（失效联动）", text.contains("红线①失效联动"))
        // 红线②：不落盘注释
        assertTrue("缺少红线②注释（绝不落盘）", text.contains("红线②"))
        assertTrue("缺少红线②注释（绝不落盘）", text.contains("绝不落盘"))
        // 红线③：大图红线注释
        assertTrue("缺少红线③注释（大图红线）", text.contains("红线③"))
        assertFalse("大图红线注释被误删？", !text.contains("临时文件即看即清"))
    }
}
