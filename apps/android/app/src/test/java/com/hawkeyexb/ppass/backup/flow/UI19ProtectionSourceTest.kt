// UI-19 步骤 1：`flow-transfer-protection.json` 记的「保护结果」当前不可信。
//
// E3 真机（2026-09-22）：系统 `FGS (dataSync) timed out` 发生在 17:51:15.688，
// 落盘的却是 {"lastOutcome":"STARTED","lastOutcomeAt":…706} —— timeout 之后
// 18 毫秒记的仍是 STARTED，而同一时刻 gate 确实进了 PAUSED_BY_USER。
// 不是「没记」（onTimeout 明确 record 了），是**记了之后被覆盖**。
//
// 覆盖它的那次写入来自 FlowTransferForeground.sync：那里的 start() 是
// ContextCompat.startForegroundService，只把请求交给系统就返回，**没有任何
// 机会观测系统同不同意**，却写出了跟真 startForeground 一模一样的 STARTED。
// 这里钉的就是一条：**有观测分量的结论不得被无观测分量的结论覆盖。**
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.R
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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

    // E3 那 18 毫秒本身：onTimeout 记下系统亲口说的配额耗尽，紧接着一次
    // sync（startForegroundService 成功返回）把它抹成了「一切正常」。
    // 反证：把 sync 的 successOutcome 改回 STARTED，这条必红。
    @Test
    fun a_submitted_request_must_not_erase_the_observed_budget_exhaustion() {
        val store = TransferProtectionStore(tempDir("e3"))
        // 17:51:15.688 —— onTimeout
        store.record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 1_758_534_675_688L)

        // …706 —— 一次并发 Flow 触发走到 sync，start() 顺利返回
        var paused = 0
        val outcome = startProtectedForeground(
            store = store,
            now = 1_758_534_675_706L,
            haltTransfer = { paused += 1 },
            successOutcome = ForegroundStartOutcome.START_REQUESTED,
        ) { /* ContextCompat.startForegroundService 成功返回 */ }

        assertEquals(ForegroundStartOutcome.START_REQUESTED, outcome)
        assertEquals("提交请求成功不是失败，不许顺手把这一轮暂停掉", 0, paused)
        assertEquals(
            "timeout 之后 18 毫秒的一次无观测写入，不许把系统亲口说的配额耗尽抹掉",
            TransferProtection.NOT_EFFECTIVE,
            transferProtectionOf(store.load()),
        )
        assertEquals(
            "那句人话必须还在——UI 读到的理由不能被毫秒级地抹掉",
            R.string.state_background_budget_paused,
            transferProtectionNoticeRes(store.load()),
        )
    }

    // #299 (MOB-97) 口径：证据不足 = 未知，且「未知」不得是一句安心话。
    // 只提交过请求就属于证据不足。
    @Test
    fun a_submitted_request_alone_is_unknown_and_says_nothing() {
        val store = TransferProtectionStore(tempDir("unknown"))
        assertTrue(store.record(ForegroundStartOutcome.START_REQUESTED, 1_000L))

        assertEquals(
            "没观测到系统同意，就不许报「保护生效」",
            TransferProtection.UNKNOWN,
            transferProtectionOf(store.load()),
        )
        assertNull("不知道就闭嘴，不许编一句理由", transferProtectionNoticeRes(store.load()))
    }

    // 优先级不是「失败永远赢」：配额会在用户把 App 切回前台后重置，
    // 此时 onStartCommand 真的观测到 startForeground 成功——同等证据分量，
    // 后来的观测必须能翻盘，否则就是把反方向的谎话冻住。
    @Test
    fun a_later_observed_start_does_take_over_from_an_earlier_refusal() {
        val store = TransferProtectionStore(tempDir("reset"))
        store.record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 1_000L)

        val outcome = startProtectedForeground(
            store = store,
            now = 2_000L,
            haltTransfer = { error("观测到启动成功时不许暂停") },
            successOutcome = ForegroundStartOutcome.STARTED,
        ) { /* startForeground 成功返回 */ }

        assertEquals(ForegroundStartOutcome.STARTED, outcome)
        assertEquals(
            "同等证据分量下，后来的观测必须能翻盘",
            TransferProtection.EFFECTIVE,
            transferProtectionOf(store.load()),
        )
    }

    // lastOutcomeAt 不是只写不读：同等证据分量时它就是判据——MOB-102 的
    // 同毫秒双线程竞争里，晚到的旧结论不许把新结论踩掉。
    @Test
    fun an_out_of_order_record_of_equal_evidence_does_not_clobber_the_newer_fact() {
        val store = TransferProtectionStore(tempDir("ooo"))
        store.record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 3_000L)

        assertTrue("落后的写入不是失败，不许报成写不进去", store.record(ForegroundStartOutcome.STARTED, 2_999L))
        assertEquals(
            "同一次启动尝试里晚到的旧结论必须让位给新结论",
            TransferProtection.NOT_EFFECTIVE,
            transferProtectionOf(store.load()),
        )
        assertEquals(3_000L, store.load().lastOutcomeAt)
    }

    // 但「时间倒流」不等于「竞争」：墙上时钟往回跳超过一次启动尝试的时长，
    // 最新的观测必须能落地，否则陈旧的「生效」会被冻在那里。
    @Test
    fun a_backwards_clock_never_freezes_a_stale_verdict() {
        val store = TransferProtectionStore(tempDir("clock"))
        store.record(ForegroundStartOutcome.STARTED, 100_000L)

        val recorded = store.record(
            ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED,
            100_000L - START_ATTEMPT_WINDOW_MS - 1L,
        )

        assertTrue(recorded)
        assertEquals(
            "时钟回跳超过一次启动尝试的时长时，最新的观测必须落地",
            TransferProtection.NOT_EFFECTIVE,
            transferProtectionOf(store.load()),
        )
    }
}
