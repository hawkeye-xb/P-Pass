package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.flow.WaitReason
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * MOB-71 → #413: a Wi-Fi wait is the engine's WAITING(WIFI), not a separate `wifiDeferred` flag in
 * MainActivity. The old guarantee still holds: once the user disables Wi-Fi-only, the stale
 * "will run once Wi-Fi is available" line must not render while the engine has not re-checked yet.
 */
class MOB71WifiDeferredHintTest {
    private val wifi = BackupUiState.Waiting(WaitReason.WIFI)
    private val res = R.string.wifi_deferred_hint

    @Test
    fun turningWifiOnlyOffDoesNotKeepTheStaleWifiWait() {
        assertEquals(
            "a stale Wi-Fi wait must fall back to the generic waiting line after Wi-Fi-only is off",
            R.string.backup_waiting_constraints,
            visibleWaitReasonRes(wifi, MediaAccess.FULL, pairingLost = false, reasonRes = res, wifiOnly = false),
        )
    }

    @Test
    fun enabledWifiOnlyOnMeteredNetworkStillShowsTheWait() {
        assertEquals(res, visibleWaitReasonRes(wifi, MediaAccess.FULL, pairingLost = false, reasonRes = res, wifiOnly = true))
    }

    @Test
    fun busyPausedOrPartialAccessSuppressesTheWait() {
        assertNull(visibleWaitReasonRes(BackupUiState.Sending(1, 2, "a.jpg"), MediaAccess.FULL, false, res))
        assertNull(visibleWaitReasonRes(BackupUiState.Paused, MediaAccess.FULL, false, res))
        assertNull(visibleWaitReasonRes(wifi, MediaAccess.PARTIAL, false, res))
    }

    // 平行状态删干净：MainActivity 不再自己存「排队中」，HomeScreen 也不再收这个参数。
    // 反证：把 `var wifiDeferred` 加回 MainActivity → 红。
    @Test
    fun thereIsNoParallelWifiDeferredState() {
        val main = File("src/main/java/com/hawkeyexb/ppass")
        assertFalse(File(main, "MainActivity.kt").readText().contains("wifiDeferred"))
        assertFalse(File(main, "ui/HomeScreen.kt").readText().contains("wifiDeferred"))
    }

    // 关掉「仅 Wi‑Fi」后立即唤醒引擎，让等待原因当场更新（人在场）。
    @Test
    fun turningWifiOnlyOffWakesTheEngine() {
        val activity = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val confirm = activity.substringAfter("if (pendingWifiOff) {").substringBefore("dismissButton")
        assertEquals(true, confirm.contains("requestFlowWake(context, TriggerReason.MANUAL)"))
    }
}
