// #1220：「仅 Wi‑Fi」看有没有不计流量的网，并把流量固定到它上面；固定不了就不连桌面。
package com.hawkeyexb.ppass.backup.flow

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class I1220RouteTest {
    private fun net(id: String, unmetered: Boolean, internet: Boolean = true, vpn: Boolean = false) =
        NetFacts(id, unmetered = unmetered, internet = internet, vpn = vpn)

    private val cellular = net("cell", unmetered = false)
    private val wifi = net("wifi", unmetered = true)

    // 场景本体：Wi‑Fi 测不到外网，默认网络被切到移动数据，Wi‑Fi 仍连着——流量固定到 Wi‑Fi。
    // 反证：判据只看默认网络（旧 isOnUnmetered）→ NoUnmetered，红。
    @Test
    fun `metered default with an unmetered network alongside pins the unmetered one`() {
        assertEquals(RouteChoice.Pin("wifi"), chooseRoute(wifiOnly = true, active = cellular, all = listOf(cellular, wifi)))
        assertTrue(hasUnmetered(cellular, listOf(cellular, wifi)))
    }

    @Test
    fun `no binding when it is not needed`() {
        assertEquals("没开仅 Wi‑Fi", RouteChoice.Default, chooseRoute(wifiOnly = false, active = cellular, all = listOf(cellular, wifi)))
        assertEquals("默认网络本身不计流量", RouteChoice.Default, chooseRoute(wifiOnly = true, active = wifi, all = listOf(cellular, wifi)))
        val vpn = net("vpn", unmetered = true, vpn = true)
        assertEquals("不绕开用户的 VPN", RouteChoice.Default, chooseRoute(wifiOnly = true, active = vpn, all = listOf(vpn, cellular, wifi)))
    }

    @Test
    fun `only metered networks means no unmetered route`() {
        assertEquals(RouteChoice.NoUnmetered, chooseRoute(wifiOnly = true, active = cellular, all = listOf(cellular)))
        assertFalse(hasUnmetered(cellular, listOf(cellular)))
        assertEquals("没有任何网络", RouteChoice.NoUnmetered, chooseRoute<String>(wifiOnly = true, active = null, all = emptyList()))
    }

    @Test
    fun `an unmetered network without internet capability is not a candidate`() {
        val local = net("p2p", unmetered = true, internet = false)
        assertEquals(RouteChoice.NoUnmetered, chooseRoute(wifiOnly = true, active = cellular, all = listOf(cellular, local)))
    }

    @Test
    fun `no default network but an unmetered one is up pins it`() {
        assertEquals(RouteChoice.Pin("wifi"), chooseRoute(wifiOnly = true, active = null, all = listOf(wifi)))
    }

    // 条件满足但流量固定不了（系统拒绝绑定）：不探测、不问 presence、不传——按「等 Wi‑Fi」，绝不退回移动数据。
    // 反证：引擎忽略 ensure() 的结果 → probes = 1，红。
    @Test
    fun `a route that cannot be pinned waits for wifi without touching the desktop`() = runTest {
        val rig = Rig(this)
        rig.conditions = Conditions(wifiOnly = true, onUnmetered = true)
        rig.routeOk = false
        rig.photo(1, generation = 1)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(WaitReason.WIFI, rig.control.waitReason())
        assertEquals(0, rig.probes)
        assertEquals(0, rig.presenceCalls)
        assertEquals(0, rig.foreground.acquires)
        assertTrue(rig.delivery.deliveredMediaIds.isEmpty())
        rig.close()
    }

    // 先选路、后连桌面：presence（5h 兜底轮问「还在吗」）与探测都排在选路之后。
    // 反证：把 ensure() 挪到 probe 之后 → netEvents 以 presence / probe 开头，红。
    @Test
    fun `the route is settled before anything talks to the desktop`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals("route", rig.netEvents.first())
        assertTrue("探测发生了", "probe" in rig.netEvents)
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // 条件本身不满足（没有任何不计流量的网）：在选路之前就停，不碰选路。
    @Test
    fun `unmet conditions stop before the route is consulted`() = runTest {
        val rig = Rig(this)
        rig.conditions = Conditions(wifiOnly = true, onUnmetered = false)
        rig.photo(1, generation = 1)
        rig.trigger()
        assertEquals(WaitReason.WIFI, rig.control.waitReason())
        assertTrue(rig.netEvents.isEmpty())
        rig.close()
    }
}
