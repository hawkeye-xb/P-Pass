// #513：界面上描述「自动备份条件」的文案，必须与 TriggerPolicy 的真实判定一致。
//
// MOB-10 早已把后台档的 requiresCharging 换成 requiresBatteryNotLow，但文案仍写「插电 + Wi-Fi」，
// 用户会以为不插电就不备份。本文件把文案钉在 constraintsFor(BACKGROUND, 默认设置) 上：
// - 默认 requiresUnmetered → 每条都要说 Wi-Fi（统一写 ASCII 连字符的 "Wi-Fi"）；
// - requiresBatteryNotLow → 每条都要说电量 / battery；
// - 任何一条都不许再出现充电类字样。
//
// 只查下面这几个 key，不对整份 strings.xml 禁「充电」：state_waiting_battery（「电量低，充电后自动接着备份」）
// 说的是电量低时的恢复路径，那是实话。
//
// #581：auto_backup_rule / auto_backup_pause_hint 是无引用死文案（lint-baseline 登记 UnusedResources），
// 已随 #581 删除；同卡新增 idle_auto_hint_any_network——关掉「仅 Wi-Fi」后首页空闲行不许再承诺 Wi-Fi。
//
// 反证：把任一 key 还原成旧文案（如 zh idle_auto_hint「插电 + Wi-Fi 时自动进行」）→ 红；
// 去掉 idleHintRes 的 wifiOnly 分支 → `idle hint with wifi-only off does not promise Wi-Fi` 红。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackupConstraintsSpec
import com.hawkeyexb.ppass.backup.BackupSettingsState
import com.hawkeyexb.ppass.backup.BackupTier
import com.hawkeyexb.ppass.backup.BackgroundBackupState
import com.hawkeyexb.ppass.backup.constraintsFor
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB513BackupConditionCopyTest {
    /** 描述后台自动备份默认条件的文案（HomeScreen 空闲行 / BucketScreen 摘要）。
     *  #581 前还有 auto_backup_rule / auto_backup_pause_hint 两条，全仓无引用，已删。 */
    private val conditionKeys = listOf("idle_auto_hint", "bucket_summary")

    private val res = File("src/main/res")
    private val zh = File(res, "values-zh/strings.xml").readText()
    private val en = File(res, "values/strings.xml").readText()

    private fun line(xml: String, key: String) =
        xml.lines().single { it.contains("name=\"$key\"") }.substringAfter(">").substringBefore("</string>")

    private val chargingWords = listOf("插电", "充电", "电源", "charg", "power", "plug")

    @Test
    fun `the copy describes exactly the background constraints TriggerPolicy applies by default`() {
        val spec = constraintsFor(BackupTier.BACKGROUND, BackupSettingsState())
        // 前提：默认设置下后台档确实是「Wi-Fi + 电量不低」。前提变了，文案要跟着重写，这里先红。
        assertTrue("默认后台档要求 Wi-Fi", spec.requiresUnmetered)
        assertTrue("后台档要求电量不低", spec.requiresBatteryNotLow)

        for (key in conditionKeys) {
            val z = line(zh, key)
            val e = line(en, key)
            if (spec.requiresUnmetered) {
                assertTrue("zh $key 要说 Wi-Fi：$z", z.contains("Wi-Fi"))
                assertTrue("en $key 要说 Wi-Fi：$e", e.contains("Wi-Fi"))
            }
            if (spec.requiresBatteryNotLow) {
                assertTrue("zh $key 要说电量不低：$z", z.contains("电量不低"))
                assertTrue("en $key 要说电量：$e", e.contains("battery", ignoreCase = true))
            }
            for (w in chargingWords) {
                assertFalse("zh $key 不许再写充电条件「$w」：$z", z.contains(w, ignoreCase = true))
                assertFalse("en $key 不许再写充电条件「$w」：$e", e.contains(w, ignoreCase = true))
            }
            assertFalse("zh $key 统一写 Wi-Fi：$z", z.contains("WiFi"))
            assertFalse("en $key 统一写 Wi-Fi：$e", e.contains("WiFi"))
        }
    }

    @Test
    fun `the constraint spec has no charging dimension to describe`() {
        // 文案不提充电的依据：约束描述里根本没有这一维。有人把 requiresCharging 加回来，这里红，
        // 提醒同时回头改上面那组文案。
        val fields = BackupConstraintsSpec::class.java.declaredFields.map { it.name.lowercase() }
        assertTrue("约束字段：$fields", fields.none { it.contains("charg") })
    }

    @Test
    fun `the local recount copy does not imply charging is a normal condition`() {
        // hero_unreconciled_body 原先写「不用等插电或 Wi-Fi」，暗示平时备份要等插电。
        assertFalse(line(zh, "hero_unreconciled_body").contains("插电"))
        assertFalse(line(en, "hero_unreconciled_body").contains("power", ignoreCase = true))
    }

    @Test
    fun `idle hint with wifi-only off does not promise Wi-Fi`() {
        // #581：关掉「仅 Wi-Fi 时备份」后后台档不再要求 unmetered（移动网络也会备份），
        // 首页空闲行必须换成不提 Wi-Fi 的那句。
        val spec = constraintsFor(BackupTier.BACKGROUND, BackupSettingsState(wifiOnly = false))
        assertFalse("关掉仅 Wi-Fi 后后台档不再要求 unmetered", spec.requiresUnmetered)

        assertEquals(R.string.idle_auto_hint, idleHintRes(BackgroundBackupState.Armed, wifiOnly = true))
        assertEquals(R.string.idle_auto_hint_any_network, idleHintRes(BackgroundBackupState.Armed, wifiOnly = false))

        val z = line(zh, "idle_auto_hint_any_network")
        val e = line(en, "idle_auto_hint_any_network")
        assertFalse("zh 关掉仅 Wi-Fi 后不提 Wi-Fi：$z", z.contains("Wi-Fi"))
        assertFalse("en 关掉仅 Wi-Fi 后不提 Wi-Fi：$e", e.contains("Wi-Fi"))
        assertTrue("zh 仍说电量不低：$z", z.contains("电量不低"))
        assertTrue("en 仍说电量：$e", e.contains("battery", ignoreCase = true))
        for (w in chargingWords) {
            assertFalse("zh idle_auto_hint_any_network 不许写充电条件「$w」：$z", z.contains(w, ignoreCase = true))
            assertFalse("en idle_auto_hint_any_network 不许写充电条件「$w」：$e", e.contains(w, ignoreCase = true))
        }
    }
}
