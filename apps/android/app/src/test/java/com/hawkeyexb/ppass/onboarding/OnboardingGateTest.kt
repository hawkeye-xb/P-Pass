// onboarding 闸门（#1321，docs/decisions/2026-11-03-onboarding-gate.md）：配对后先做备份决定，「连过」由决定落盘。
// 判断 A / B 见 #1321 评论：补记只在升级后第一次启动做一次；冷启动先补记再按记录判去向。
package com.hawkeyexb.ppass.onboarding

import com.hawkeyexb.ppass.DecisionLanding
import com.hawkeyexb.ppass.Screen
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.OnboardedDesktopsStore
import com.hawkeyexb.ppass.backup.isKnownDesktop
import com.hawkeyexb.ppass.decisionLanding
import com.hawkeyexb.ppass.launchScreen
import com.hawkeyexb.ppass.transport.Pairing
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OnboardingGateTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val mac = "a".repeat(64)
    private val win = "b".repeat(64)
    private fun pairing(node: String) = Pairing(daemonNodeId = node, daemonAddrToken = "t", storageDeviceName = "Home")
    private fun store() = OnboardedDesktopsStore(tmp.root)
    private fun file() = File(tmp.root, "onboarded_desktops.json")

    /** 按 nodeId 分的范围（语义同 BackupScopeStore；SharedPreferences 在 JVM 上跑不起来）。 */
    private val scopes = mutableMapOf<String, Set<Long>>()
    private var scopeReads = 0
    private fun scopeNonEmpty(node: String): () -> Boolean = { scopeReads++; scopes[node]?.isNotEmpty() == true }

    /** MainActivity 配对成功分支：`if (hasExistingLedgerFor(p)) Home else Decision`，hasExistingLedgerFor 就是 isKnownDesktop。 */
    private fun afterPairing(node: String): Screen =
        if (isKnownDesktop(store(), node, scopeNonEmpty(node))) Screen.Home(pairing(node)) else Screen.Decision(pairing(node))

    private val main by lazy { File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText() }

    // ── 配对后的分流：完整判据 ────────────────────────────────

    @Test
    fun pairing_routes_new_desktops_to_the_decision_page_and_known_ones_home() {
        assertTrue("首次", afterPairing(mac) is Screen.Decision)
        store().markOnboarded(mac)
        scopes[mac] = setOf(1L)
        assertTrue("连过：有记录 + 这台范围非空", afterPairing(mac) is Screen.Home)
    }

    @Test
    fun known_needs_both_the_record_and_this_desktops_scope() {
        // 反证：判据只看记录，「有记录无范围」这条红。
        store().markOnboarded(mac)
        assertTrue("有记录无范围 → 新电脑", afterPairing(mac) is Screen.Decision)
        scopes[win] = setOf(7L)
        assertTrue("无记录有范围（MOB-92 认领）→ 新电脑", afterPairing(win) is Screen.Decision)
        assertTrue("两者都无 → 新电脑", afterPairing("c".repeat(64)) is Screen.Decision)
    }

    @Test
    fun pairing_itself_never_writes_the_record() {
        afterPairing(mac)
        assertFalse("配对成功不落盘，决定页选择后才落盘", store().wasOnboarded(mac))
        // 接线（本仓没有 Robolectric，按源码形状钉）：配对成功整段不落「连过」，新电脑进决定页。
        // 反证：把 markOnboarded / markDecided 放回配对成功分支，这条红。
        val joined = main.substringAfter("is PairOutcome.Joined -> {").substringBefore("is PairOutcome.Refused ->")
        assertTrue(joined.contains("if (hasExistingLedgerFor(outcome.pairing)) {"))
        assertTrue(joined.contains("screen = Screen.Decision(outcome.pairing)"))
        assertFalse(joined.contains("markOnboarded"))
        assertFalse(joined.contains("markDecided"))
        assertTrue(main.contains("fun hasExistingLedgerFor(pairing: Pairing): Boolean =\n        isKnownDesktop("))
    }

    @Test
    fun cold_start_uses_the_record_and_the_backfill_runs_at_process_start() {
        assertTrue(main.contains("launchScreen(pairings.load(), OnboardedDesktopsStore(context.filesDir)::wasOnboarded)"))
        val app = File("src/main/java/com/hawkeyexb/ppass/PPassApplication.kt").readText()
        val notify = app.indexOf("NotifyOnFailurePrefs(filesDir).initIfAbsent(")
        val backfill = app.indexOf("OnboardedDesktopsStore(filesDir).initIfAbsent(")
        assertTrue("补记在进程启动时做", backfill > 0)
        assertTrue("排在「老用户」判定之后（那里要求先于任何 markOnboarded）", backfill > notify)
    }

    // ── 决定页主按钮：照片权限三态 ────────────────────────────

    @Test
    fun decision_main_button_lands_by_photo_permission() {
        assertEquals(DecisionLanding.ChooseScope, decisionLanding(MediaAccess.FULL))
        assertEquals(
            "部分允许：系统权限框里已选过照片，直接登记，不再弹选图器（三星验收选两遍）",
            DecisionLanding.RegisterAllowed,
            decisionLanding(MediaAccess.PARTIAL),
        )
        assertEquals(DecisionLanding.PickPhotos, decisionLanding(MediaAccess.NONE))
    }

    /**
     * 部分允许的接线：权限框回调里 RegisterAllowed 分支不打开选图器，用已授权照片登记、落盘 via=partial、进照片页。
     * 反证：恢复旧路由（部分允许 → `launchDecisionPick`），本条红。
     */
    @Test
    fun partial_access_registers_allowed_photos_instead_of_opening_the_picker() {
        val callback = main.substringAfter("val decisionPermission = rememberLauncherForActivityResult")
            .substringBefore("val onDecisionChooseScope")
        assertTrue(callback.contains("DecisionLanding.RegisterAllowed -> registerDecisionAllowed(pairing)"))
        assertFalse("部分允许不再弹选图器", Regex("RegisterAllowed -> launchDecisionPick").containsMatchIn(callback))
        val register = main.substringAfter("val registerDecisionAllowed").substringBefore("// 主按钮「选择备份范围」")
        assertTrue(register.contains("PickedUploads.enqueueAllowedImages(context)"))
        assertTrue(register.contains("markDecided(pairing, \"partial\")"))
        assertTrue(register.contains("screen = Screen.Home(pairing)"))
        assertFalse(register.contains("PickMultipleVisualMedia"))
    }

    // ── 判断 A：补记只在升级后第一次启动做一次 ───────────────

    @Test
    fun upgrade_backfills_the_desktop_paired_at_that_moment_once() {
        // 升级前的老文件：有别的记录，没有 initialized 字段。
        file().writeText("""{"nodeIds":["${"d".repeat(64)}"]}""")
        scopes[mac] = setOf(1L)
        assertTrue(store().initIfAbsent(mac, scopeNonEmpty(mac)))
        assertTrue(store().wasOnboarded(mac))
        assertTrue("老记录原样保留", store().wasOnboarded("d".repeat(64)))
        assertFalse("只补一次", store().initIfAbsent(mac, scopeNonEmpty(mac)))
    }

    @Test
    fun upgrade_without_scope_does_not_backfill() {
        assertFalse(store().initIfAbsent(mac, scopeNonEmpty(mac)))
        assertFalse(store().wasOnboarded(mac))
    }

    @Test
    fun a_new_desktop_that_inherited_the_legacy_scope_is_not_backfilled_after_init() {
        // 新装 / 升级时没有配对：初始化做完。
        assertFalse(store().initIfAbsent(null) { error("没有配对不读范围") })
        // 之后配一台从没连过的新电脑，MOB-92 一次性认领让它的范围非空。
        scopes[win] = setOf(7L)
        // 反证：恢复「每次进照片页补记」或去掉「已初始化」判断，这条红。
        assertFalse(store().initIfAbsent(win, scopeNonEmpty(win)))
        assertFalse(store().wasOnboarded(win))
        assertTrue(afterPairing(win) is Screen.Decision)
        assertTrue(launchScreen(pairing(win), store()::wasOnboarded) is Screen.Decision)
    }

    @Test
    fun init_does_not_read_the_scope_when_there_is_nothing_to_backfill() {
        store().markOnboarded(mac) // 新版本写下的文件已带「已初始化」
        scopeReads = 0
        store().initIfAbsent(win, scopeNonEmpty(win))
        assertEquals("不补的情况下不读范围（读范围会触发 MOB-92 认领）", 0, scopeReads)
    }

    @Test
    fun a_corrupt_record_file_is_not_backfilled() {
        file().writeText("not json")
        scopes[mac] = setOf(1L)
        assertFalse(store().initIfAbsent(mac, scopeNonEmpty(mac)))
        assertFalse("损坏 = 多问一次", store().wasOnboarded(mac))
    }

    @Test
    fun records_written_by_this_version_count_as_initialized() {
        store().markOnboarded(mac)
        scopes[win] = setOf(7L)
        assertFalse(store().initIfAbsent(win, scopeNonEmpty(win)))
        assertTrue(file().readText().contains("\"initialized\":true"))
    }

    // ── 判断 B：冷启动先补记，再只按记录判去向 ───────────────

    @Test
    fun cold_start_routes_by_the_record_only() {
        assertEquals(Screen.Welcome, launchScreen(null, store()::wasOnboarded))
        assertTrue("有配对、没做过决定（含决定页被杀）", launchScreen(pairing(mac), store()::wasOnboarded) is Screen.Decision)
        store().markOnboarded(mac)
        scopes[mac] = setOf(1L)
        assertTrue("有记录有范围", launchScreen(pairing(mac), store()::wasOnboarded) is Screen.Home)
        scopes.remove(mac)
        // 反证：冷启动改用完整判据（记录 && 范围），单张备份的用户每次打开都被拦进决定页，这条红。
        assertTrue("有记录无范围（单张备份）", launchScreen(pairing(mac), store()::wasOnboarded) is Screen.Home)
    }

    @Test
    fun cold_start_backfills_before_routing() {
        scopes[mac] = setOf(1L)
        store().initIfAbsent(mac, scopeNonEmpty(mac))
        assertTrue("升级上来的老用户不被拦进决定页", launchScreen(pairing(mac), store()::wasOnboarded) is Screen.Home)
    }
}
