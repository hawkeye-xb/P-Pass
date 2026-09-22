// UI-19 步骤 1：`flow-transfer-protection.json` 记的「保护结果」当前不可信。
//
// E3 真机（2026-09-22）：系统 `FGS (dataSync) timed out` 发生在 17:51:15.688，
// 落盘的却是 {"lastOutcome":"STARTED","lastOutcomeAt":…706} —— timeout 之后
// 18 毫秒记的仍是 STARTED，而同一时刻 gate 确实进了 PAUSED_BY_USER。
// 不是「没记」（onTimeout 明确 record 了），是**记了之后被覆盖**。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UI19ProtectionSourceTest {

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-ui19-$case").toFile()

    private fun serviceSource(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowTransferForegroundService.kt",
        ).readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")
    }

    /** 两个写入者各自在 `startProtectedForeground(` 之后声明的成功 outcome。 */
    private fun successOutcomeByCallSite(): Map<String, String?> {
        val source = serviceSource()
        val result = mutableMapOf<String, String?>()
        Regex("startProtectedForeground\\(").findAll(source).forEach { match ->
            val window = source.substring(match.range.first, minOf(source.length, match.range.first + 900))
            val site = when {
                window.contains("ContextCompat.startForegroundService") -> "sync"
                window.contains("startForeground(NOTIFICATION_ID") -> "onStartCommand"
                else -> return@forEach
            }
            result[site] = Regex("ForegroundStartOutcome\\.([A-Z_]+)").find(window)?.groupValues?.get(1)
        }
        return result
    }

    // 「提交了启动请求」≠「保护已生效」：`ContextCompat.startForegroundService`
    // 根本不走 startForeground，没有任何机会观测系统是否同意，它的成功不许
    // 写出 onStartCommand 那个真 startForeground 才配写的值。
    @Test
    fun the_two_writers_must_not_record_the_same_success_outcome() {
        val sites = successOutcomeByCallSite()
        assertEquals("两个写入者都必须走同一条 seam", setOf("sync", "onStartCommand"), sites.keys)
        val submitted = sites["sync"]
        val observed = sites["onStartCommand"]
        assertNotNull(
            "sync 的 start() 只提交了一次启动请求，必须显式声明一个「未观测」的成功 outcome",
            submitted,
        )
        assertNotNull("onStartCommand 才有证据分量，同样必须把它声明出来", observed)
        assertTrue(
            "提交请求与系统已同意不许写出同一个值，实际：sync=$submitted onStartCommand=$observed",
            submitted != observed,
        )
    }

    // E3 那 18 毫秒：已观测到的配额耗尽，被一个毫无观测分量的 STARTED 抹掉。
    // 【临时用例，仅用于取 RED 原文】修好之后 sync 写的不再是 STARTED，
    // 这条会按新写入者语义重写。
    @Test
    fun an_unobserved_start_must_not_erase_the_observed_budget_exhaustion() {
        val store = TransferProtectionStore(tempDir("e3"))
        store.record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 1_758_534_675_688L)
        store.record(ForegroundStartOutcome.STARTED, 1_758_534_675_706L)

        assertEquals(
            "timeout 之后 18 毫秒的一次无观测写入，不许把系统亲口说的配额耗尽抹掉",
            TransferProtection.NOT_EFFECTIVE,
            transferProtectionOf(store.load()),
        )
    }
}
