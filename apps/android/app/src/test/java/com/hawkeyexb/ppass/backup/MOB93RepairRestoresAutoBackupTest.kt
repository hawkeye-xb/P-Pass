// MOB-93: 重连回以前连过的电脑之后，自动备份必须自己回来。
//
// 验收人 2026-09-21 真机取证：19:55:29 有一次成功的快速重连，而
// `ppass-auto-backup`（5 小时周期，KEY_RECONCILE_REMOTE 的唯一载体）
// 状态仍是 CANCELLED，最后一次写入停在 19:32:03。于是兜底对账没有
// 载体、切后台回来不补捞、相册变更不再触发——三条链静默全死。
//
// 成因不是谁写错了代码，是一个**只写在注释里的不变量**被后来的改动
// 打破：`clearLocalPairing` 清掉备份意图，理由写的是「下一轮 onboarding
// 会重新问」；#257 加了快速重连，那一轮 onboarding 不再必然发生。
//
// 所以这里测的是行为，不是源文本：AutoBackupPrefs 就是文件 IO，纯 JVM
// 跑得动，断开→重连这一整条往返可以真的走一遍。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MOB93RepairRestoresAutoBackupTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 用户开过后台备份（enableAutoBackup 落盘的那两位）。 */
    private fun userHadBackupOn() = AutoBackupPrefs(tmp.root).apply {
        setRequested(true)
        setEnabled(true)
    }

    // ── 断开：停生产者，留意图 ──────────────────────────────────
    @Test
    fun disconnect_stops_producers_but_keeps_the_users_intent() {
        userHadBackupOn()

        suspendAutoBackupForPairingChange(tmp.root)

        val prefs = AutoBackupPrefs(tmp.root)
        assertFalse("断开必须停掉生产者", prefs.enabled())
        assertTrue("断开不许把用户的意图一起清掉——这正是本卡的 bug", prefs.requested())
    }

    @Test
    fun disconnect_does_not_invent_an_intent_the_user_never_had() {
        // 从没开过后台备份的用户，断开之后也不该凭空多出一个意图。
        suspendAutoBackupForPairingChange(tmp.root)

        assertFalse(AutoBackupPrefs(tmp.root).requested())
        assertFalse(AutoBackupPrefs(tmp.root).enabled())
    }

    @Test
    fun a_legacy_file_without_an_explicit_intent_keeps_its_effective_one() {
        // 老文件里 userRequested 可能是 null，取值回退到当时的 autoEnabled。
        // 先固化再置 false，否则这一步自己就把意图抹了。
        File(tmp.root, "auto_backup_prefs.json").writeText("""{"autoEnabled":true}""")

        suspendAutoBackupForPairingChange(tmp.root)

        assertTrue("老文件的意图要先固化再停", AutoBackupPrefs(tmp.root).requested())
        assertFalse(AutoBackupPrefs(tmp.root).enabled())
    }

    // ── 重连：按意图恢复 ───────────────────────────────────────
    @Test
    fun a_kept_intent_plus_live_authorization_means_turn_it_back_on() {
        assertEquals(
            AutoBackupResume.ENABLE,
            autoBackupResumeDecision(userRequested = true, backgroundAuthorized = true),
        )
    }

    @Test
    fun a_kept_intent_without_authorization_waits_instead_of_starting() {
        assertEquals(
            AutoBackupResume.SUSPEND,
            autoBackupResumeDecision(userRequested = true, backgroundAuthorized = false),
        )
    }

    @Test
    fun no_intent_is_never_upgraded_into_one() {
        // 用户没要后台备份，重连不许替他打开——授权在不在都一样。
        assertEquals(
            AutoBackupResume.LEAVE_OFF,
            autoBackupResumeDecision(userRequested = false, backgroundAuthorized = true),
        )
        assertEquals(
            AutoBackupResume.LEAVE_OFF,
            autoBackupResumeDecision(userRequested = false, backgroundAuthorized = false),
        )
    }

    // ── 整条往返：这是真机上失败的那一条 ────────────────────────
    @Test
    fun the_round_trip_that_failed_on_the_device() {
        userHadBackupOn()

        // 1. 断开
        suspendAutoBackupForPairingChange(tmp.root)
        assertFalse(AutoBackupPrefs(tmp.root).enabled())

        // 2. 重连回**同一台**电脑（快速路径，跳过 onboarding）
        val verdict = autoBackupResumeDecision(
            userRequested = AutoBackupPrefs(tmp.root).requested(),
            backgroundAuthorized = true,
        )
        assertEquals(
            "重连回以前连过的电脑必须把生产者排回来，否则兜底对账没有载体",
            AutoBackupResume.ENABLE,
            verdict,
        )
    }

    @Test
    fun switching_to_a_different_desktop_asks_again_instead_of_inheriting() {
        userHadBackupOn()
        suspendAutoBackupForPairingChange(tmp.root)

        // 换新电脑走 onboarding，入口清意图（MainActivity 的 else 分支）。
        AutoBackupPrefs(tmp.root).setRequested(false)

        assertEquals(
            "新电脑 = 新的信任关系，不许继承上一台的后台备份意图",
            AutoBackupResume.LEAVE_OFF,
            autoBackupResumeDecision(
                userRequested = AutoBackupPrefs(tmp.root).requested(),
                backgroundAuthorized = true,
            ),
        )
    }

    // ── 接线：纯函数对了，没人调用也是白搭（#139 栽过这一跤）──────
    @Test
    fun the_fast_repair_path_actually_calls_the_restore() {
        val source = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

        val clearBody = source.substringAfter("private fun clearLocalPairing(")
        assertTrue(
            "断开必须走留意图的那条处置",
            clearBody.contains("suspendAutoBackupForPairingChange(context.filesDir)"),
        )
        assertFalse(
            "断开不许再把用户意图清成 false",
            clearBody.substringBefore("cancelMediaWatch").contains("setRequested(false)"),
        )

        val fastPath = source.substringAfter("if (hasExistingLedgerFor(outcome.pairing))")
            .substringBefore("enterBucketPicker(outcome.pairing, firstTime = true)")
        assertTrue(
            "快速重连路径必须恢复自动备份——这条路跳过 onboarding，没有别人会做",
            fastPath.contains("restoreAutoBackupAfterRepair("),
        )
        assertTrue(
            "换新电脑那条路要清掉意图，重新问一次",
            fastPath.contains("setRequested(false)"),
        )
    }
}
