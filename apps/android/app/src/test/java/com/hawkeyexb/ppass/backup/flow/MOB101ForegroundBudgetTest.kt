// MOB-101: the `dataSync` foreground service budget (6h / 24h since
// Android 14) runs out, `startForeground` throws
// ForegroundServiceStartNotAllowedException, and the bare call in
// onStartCommand takes the whole process down — real device, Samsung
// SM-S9210 / Android 15, 2026-09-21 16:14, twice in six seconds.
//
// What these cases pin, in the card's own words:
//   1. losing protection must not crash;
//   2. it must not become "keep sending unprotected" either — the round
//      durably pauses (反证: swallow-and-continue turns this red);
//   3. the user-facing line is plain language from strings.xml, both
//      languages;
//   4. the verdict is tri-state like #299 (MOB-97): no evidence = 未知,
//      never a reassuring "protected".
//
// Deliberately Android-free: this repo has no Robolectric and no mocking
// framework, so a real `Service` cannot be constructed here. The failure
// is matched by class NAME (see isForegroundStartRefusal), which is what
// lets the exact system exception be reproduced by a local stand-in.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB101ForegroundBudgetTest {

    /**
     * Stand-in for `android.app.ForegroundServiceStartNotAllowedException`
     * — same simple name, same ancestor (the real one is an
     * IllegalStateException), and the message is the system's own text
     * copied from the crash log in the card.
     */
    private class ForegroundServiceStartNotAllowedException(message: String) : IllegalStateException(message)

    private val budgetExhaustedMessage = "Time limit already exhausted for foreground service type dataSync"

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob101-$case").toFile()

    private fun resFile(name: String): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/res/$name/strings.xml")
    }

    // 验收 1 + 2：不崩溃，且不得继续无保护传输——必须落到明确的暂停态，
    // 并且这个暂停的理由是durable的（UI 读得到）。
    @Test
    fun budget_exhausted_start_does_not_crash_and_durably_pauses_the_round() {
        val dir = tempDir("pause")
        val store = TransferProtectionStore(dir)
        var paused = 0

        val outcome = startProtectedForeground(
            store = store,
            now = 1_700_000_000_000L,
            haltTransfer = { paused += 1 },
        ) {
            throw ForegroundServiceStartNotAllowedException(budgetExhaustedMessage)
        }

        assertEquals(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, outcome)
        assertEquals("配额耗尽必须暂停这一轮，而不是吞掉异常继续裸奔", 1, paused)
        assertEquals(
            "暂停理由必须落盘，否则 UI 只能显示一个用户没点过的「已暂停」",
            TransferProtection.NOT_EFFECTIVE,
            transferProtectionOf(store.load()),
        )
    }

    // 验收 4（#299 口径）：证据不足必须是「未知」，不许默认报「正常」。
    @Test
    fun protection_without_any_observation_is_unknown_not_effective() {
        val store = TransferProtectionStore(tempDir("unknown"))
        assertEquals(TransferProtection.UNKNOWN, transferProtectionOf(store.load()))
        assertNull("没观测过就没有话可说，不许弹提示", transferProtectionNoticeRes(store.load()))
    }

    // 同一个异常类型也用于「后台启动被拒」，那是另一个原因、另一句话。
    // 不带 Time limit 证据时只能报「未知」，不许假装知道是配额。
    @Test
    fun refusal_without_the_time_limit_evidence_is_unknown_and_still_pauses() {
        val dir = tempDir("refused")
        val store = TransferProtectionStore(dir)
        var paused = 0

        val outcome = startProtectedForeground(
            store = store,
            now = 1_700_000_000_000L,
            haltTransfer = { paused += 1 },
        ) {
            throw ForegroundServiceStartNotAllowedException(
                "startForegroundService() not allowed due to mAllowStartForeground false",
            )
        }

        assertEquals(ForegroundStartOutcome.START_REFUSED, outcome)
        assertEquals(1, paused)
        assertEquals(TransferProtection.UNKNOWN, transferProtectionOf(store.load()))
        assertNotNull("拒了就得有句人话，只是不能说是配额", transferProtectionNoticeRes(store.load()))
    }

    // 正常路径一个字节不变：成功即 STARTED，不暂停，判定为「生效」。
    @Test
    fun a_successful_protected_start_changes_nothing_and_records_effective() {
        val dir = tempDir("ok")
        val store = TransferProtectionStore(dir)
        var paused = 0
        var started = 0

        val outcome = startProtectedForeground(
            store = store,
            now = 1_700_000_000_000L,
            haltTransfer = { paused += 1 },
        ) { started += 1 }

        assertEquals(ForegroundStartOutcome.STARTED, outcome)
        assertEquals(1, started)
        assertEquals("配额充足时不许有任何暂停", 0, paused)
        assertEquals(TransferProtection.EFFECTIVE, transferProtectionOf(store.load()))
        assertNull(transferProtectionNoticeRes(store.load()))
    }

    // 不是所有 IllegalStateException 都是「前台服务被拒」。不认识的异常
    // 必须原样抛出——静默降级会把别的故障埋掉。
    @Test
    fun an_unrelated_failure_is_never_swallowed() {
        val store = TransferProtectionStore(tempDir("rethrow"))
        val thrown = runCatching {
            startProtectedForeground(store = store, now = 1L, haltTransfer = {}) {
                throw IllegalStateException("notification channel missing")
            }
        }.exceptionOrNull()
        assertTrue("不认识的失败必须暴露，不许当成配额耗尽吞掉", thrown is IllegalStateException)
        assertEquals(TransferProtection.UNKNOWN, transferProtectionOf(store.load()))
    }

    // 验收 3：文案出自 strings.xml，中英双语齐备，且不含任何技术词
    // （tokens.json：Errors never show a code or bare technical term）。
    @Test
    fun the_user_facing_lines_are_bilingual_and_free_of_technical_terms() {
        val keys = listOf("state_background_budget_paused", "state_background_protection_unknown")
        val banned = listOf(
            "dataSync", "data sync", "foreground service", "ForegroundService",
            "Exception", "quota", "API", "startForeground", "FGS",
        )
        for (locale in listOf("values", "values-zh")) {
            val text = resFile(locale).readText()
            for (key in keys) {
                assertTrue("$locale 缺少文案 $key", text.contains("name=\"$key\""))
                val line = text.lines().first { it.contains("name=\"$key\"") }
                for (term in banned) {
                    assertFalse(
                        "$locale 的 $key 出现技术词「$term」：$line",
                        line.contains(term, ignoreCase = true),
                    )
                }
            }
        }
    }
}
