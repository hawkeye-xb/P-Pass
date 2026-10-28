package com.hawkeyexb.ppass.backup

import android.net.NetworkCapabilities
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * #1220：后台唤醒的网络约束不要求系统验证过外网——代理失效、只通局域网的 Wi‑Fi 下，进程死后续传哨兵与
 * 周期兜底也要能跑。「仅 Wi‑Fi」设置照旧落成不计流量。
 */
class BackupNetworkConstraintTest {
    @Test
    fun anyNetwork_requiresOnlyInternet_neverValidated() {
        val caps = requiredNetworkCapabilities(BackupConstraintsSpec(requiresBatteryNotLow = true, requiresUnmetered = false))
        assertEquals(listOf(NetworkCapabilities.NET_CAPABILITY_INTERNET), caps)
        assertFalse(NetworkCapabilities.NET_CAPABILITY_VALIDATED in caps)
    }

    @Test
    fun wifiOnly_addsNotMetered_neverValidated() {
        val caps = requiredNetworkCapabilities(BackupConstraintsSpec(requiresBatteryNotLow = false, requiresUnmetered = true))
        assertEquals(
            listOf(NetworkCapabilities.NET_CAPABILITY_INTERNET, NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            caps,
        )
        assertFalse(NetworkCapabilities.NET_CAPABILITY_VALIDATED in caps)
    }
}
