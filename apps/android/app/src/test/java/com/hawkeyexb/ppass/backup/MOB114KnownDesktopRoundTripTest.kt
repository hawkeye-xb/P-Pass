// MOB-114（#455）：连回同一台电脑必须被认出来。
//
// 旧判据是 `flow-state/<id>/discovery-ledger.json` 在不在；#413 的
// `migrateLegacyFlowState` 删了整个 `flow-state/`，之后没人再写——判据恒为
// false，MOB-87 快速重连与 MOB-93 恢复后台备份两条分支成了死代码。
//
// 这里走的是**真的文件往返**：配对 → onboarding 完成落标记 → 断开（跑
// clearLocalPairing 里所有文件层的清理，外加 #413 那次迁移本身）→ 再配对
// 同一个 nodeId。判据函数单测不够——上一次就是判据"对"、事实被删。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.flow.migrateLegacyFlowState
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MOB114KnownDesktopRoundTripTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val macNodeId = "a".repeat(64)
    private val newNodeId = "b".repeat(64)

    /** SharedPreferences 在 JVM 上跑不起来；每台桌面的相册范围用一张表代替，
     *  语义同 BackupScopeStore：按 nodeId 分，断开不清（见 MOB92PerDesktopScopeTest）。 */
    private val scopes = mutableMapOf<String, Set<Long>>()

    private fun dir() = tmp.root

    private fun known(nodeId: String) =
        isKnownDesktop(OnboardedDesktopsStore(dir()), nodeId) { scopes[nodeId]?.isNotEmpty() == true }

    /** MainActivity 的 Joined 分支：连过 → 快速重连（留意图）；没连过 → 清意图走 onboarding。 */
    private fun rejoin(nodeId: String): Boolean {
        PairingStore(dir()).save(Pairing(daemonNodeId = nodeId, daemonAddrToken = "t", storageDeviceName = "Home"))
        val isKnown = known(nodeId)
        if (!isKnown) AutoBackupPrefs(dir()).setRequested(false)
        return isKnown
    }

    /** 首次配对 + 选相册 + 在收尾页开了后台备份 + 进入 App（finishOnboarding）。 */
    private fun onboard(nodeId: String) {
        PairingStore(dir()).save(Pairing(daemonNodeId = nodeId, daemonAddrToken = "t", storageDeviceName = "Home"))
        scopes[nodeId] = setOf(1L, 2L)
        AutoBackupPrefs(dir()).apply { setRequested(true); setEnabled(true) }
        OnboardedDesktopsStore(dir()).markOnboarded(nodeId)
    }

    /** clearLocalPairing 实际执行的那份断开清单（MOB-95：它就是全部处置；运行时
     *  那几行记账不落盘），再加上 #413 那次一次性迁移——正是它删掉了旧判据依赖的文件。 */
    private fun disconnect(nodeId: String) {
        File(dir(), "backup-state/$nodeId").mkdirs()
        File(dir(), "flow-state/$nodeId").mkdirs()
        File(dir(), "flow-state/$nodeId/discovery-ledger.json").writeText("{}")
        applyDisconnectManifest(dir(), NoRuntime)
        migrateLegacyFlowState(dir())
    }

    private object NoRuntime : DisconnectRuntime {
        override fun stopFlowRuntime() = Unit
        override fun cancelUniqueWork(name: String) = Unit
        override fun cancelMediaWatch() = Unit
    }

    @Test
    fun reconnecting_to_the_same_desktop_is_recognised_and_keeps_background_backup() {
        onboard(macNodeId)
        disconnect(macNodeId)

        assertFalse("前提：断开真的停了生产者", AutoBackupPrefs(dir()).enabled())
        assertFalse("前提：#413 迁移真的删了 flow-state/", File(dir(), "flow-state").exists())

        assertTrue("连回同一台电脑必须被认出来——#455 的 bug 就是这里恒为 false", rejoin(macNodeId))
        assertTrue("快速重连不许清掉后台备份意图", AutoBackupPrefs(dir()).requested())
        assertEquals(
            "快速重连路径要把后台备份排回来（MOB-93）",
            AutoBackupResume.ENABLE,
            autoBackupResumeDecision(AutoBackupPrefs(dir()).requested(), backgroundAuthorized = true),
        )
    }

    @Test
    fun a_desktop_never_onboarded_here_still_goes_through_onboarding() {
        onboard(macNodeId)
        disconnect(macNodeId)

        assertFalse("没连过的电脑必须走 onboarding", rejoin(newNodeId))
        assertEquals(
            "新电脑 = 新的信任关系，不许继承上一台的后台备份意图",
            AutoBackupResume.LEAVE_OFF,
            autoBackupResumeDecision(AutoBackupPrefs(dir()).requested(), backgroundAuthorized = true),
        )
    }

    @Test
    fun switching_away_and_back_still_recognises_the_first_desktop() {
        // order 表在这条路上会被 claimOwner 清空——这是不能拿它当判据的原因之一。
        onboard(macNodeId)
        disconnect(macNodeId)
        assertFalse(rejoin(newNodeId))
        onboard(newNodeId)
        disconnect(newNodeId)

        assertTrue("A → B → A：回到 A 仍然是连过的", rejoin(macNodeId))
    }

    @Test
    fun a_legacy_scope_alone_does_not_make_a_new_desktop_known() {
        // MOB-92 的一次性认领会让从没连过的桌面继承老的全局范围——范围非空
        // 不等于连过，所以才需要标记。
        scopes[newNodeId] = setOf(7L)
        assertFalse(known(newNodeId))
    }

    @Test
    fun an_onboarded_desktop_without_its_own_scope_goes_back_through_onboarding() {
        // MOB-92：范围必须按这台问；这台没有范围，就让用户重选。
        OnboardedDesktopsStore(dir()).markOnboarded(macNodeId)
        assertFalse(known(macNodeId))
    }

    @Test
    fun the_marker_survives_a_fresh_store_instance_and_a_corrupt_file_degrades_to_new() {
        OnboardedDesktopsStore(dir()).markOnboarded(macNodeId)
        OnboardedDesktopsStore(dir()).markOnboarded(newNodeId)
        assertTrue(OnboardedDesktopsStore(dir()).wasOnboarded(macNodeId))
        assertTrue(OnboardedDesktopsStore(dir()).wasOnboarded(newNodeId))

        File(dir(), "onboarded_desktops.json").writeText("not json")
        assertFalse("损坏按新电脑处理：宁可多问一次", OnboardedDesktopsStore(dir()).wasOnboarded(macNodeId))
    }

    @Test
    fun devices_onboarded_before_this_fix_are_backfilled_from_home() {
        // 存量：onboarding 在旧版本走完，没有标记；首页 + 有范围 = 连过。
        scopes[macNodeId] = setOf(1L)
        backfillOnboardedOnHome(OnboardedDesktopsStore(dir()), macNodeId) { scopes[macNodeId]?.isNotEmpty() == true }
        disconnect(macNodeId)
        assertTrue(rejoin(macNodeId))

        // 首页上没有范围（部分授权直接回首页那条路）不算走完 onboarding。
        backfillOnboardedOnHome(OnboardedDesktopsStore(dir()), newNodeId) { false }
        assertFalse(OnboardedDesktopsStore(dir()).wasOnboarded(newNodeId))
    }

    // ── 接线：判据对了、没人写 / 有人清，都是白搭 ─────────────────
    private fun main() = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    @Test
    fun onboarding_completion_writes_the_marker_and_disconnect_never_clears_it() {
        val src = main()
        val finish = src.substringAfter("val finishOnboarding = {").substringBefore("\n            }")
        assertTrue("走完 onboarding 必须落标记", finish.contains("OnboardedDesktopsStore(context.filesDir).markOnboarded(s.pairing.daemonNodeId)"))

        val clear = src.substringAfter("private fun clearLocalPairing(").substringBefore("\n}")
        assertFalse("断开 / 配对失效不许碰「连过」的标记", clear.contains("OnboardedDesktops"))
        assertFalse("断开 / 配对失效不许碰「连过」的标记", clear.contains("onboarded_desktops"))
        // MOB-95：断开的处置只在清单里——「连过」那一行必须是 KEEP，且断开真的走清单。
        assertTrue("断开必须按清单执行", clear.contains("applyDisconnectManifest("))
        assertEquals(
            "断开 / 配对失效不许碰「连过」的标记",
            DisconnectDisposition.KEEP,
            DisconnectState.ONBOARDED_DESKTOPS.disposition,
        )
        assertTrue(DisconnectState.ONBOARDED_DESKTOPS.matches("onboarded_desktops.json"))

        val predicate = src.substringAfter("fun hasExistingLedgerFor(").substringBefore("\n\n")
        assertTrue("判据必须读标记", predicate.contains("isKnownDesktop(OnboardedDesktopsStore(context.filesDir)"))
        assertFalse("判据不许再依赖 #413 删掉的文件", predicate.contains("flow-state"))
    }

    @Test
    fun the_marker_lives_outside_every_directory_that_gets_deleted_wholesale() {
        val store = File("src/main/java/com/hawkeyexb/ppass/backup/OnboardedDesktopsStore.kt").readText()
        assertTrue(store.contains("File(dir, \"onboarded_desktops.json\")"))
        OnboardedDesktopsStore(dir()).markOnboarded(macNodeId)
        disconnect(macNodeId)
        assertTrue(File(dir(), "onboarded_desktops.json").isFile)
    }
}
