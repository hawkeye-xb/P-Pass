package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.transport.Pairing
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MainBackNavigationTest {
    private val pairing = Pairing(
        daemonNodeId = "a".repeat(64),
        daemonAddrToken = "token",
        storageDeviceName = "Home",
    )

    @Test
    fun systemBackUsesTheActualScreenHistoryForEverySecondaryScreen() {
        assertEquals(Screen.Welcome, systemBackTarget(Screen.Scan))
        assertEquals(Screen.Scan, systemBackTarget(Screen.Waiting("ppf://pair/test")))
        assertEquals(Screen.Scan, systemBackTarget(Screen.Trouble(1, 2)))
        assertEquals(Screen.Home(pairing), systemBackTarget(Screen.Buckets(pairing, emptySet(), firstTime = false)))
        assertEquals(Screen.Home(pairing), systemBackTarget(Screen.Started(pairing, photoCount = 2)))
    }

    @Test
    fun rootScreensDelegateBackToAndroid() {
        assertNull(systemBackTarget(Screen.Welcome))
        assertNull(systemBackTarget(Screen.Home(pairing)))
    }

    @Test
    fun appAndLocalSecondaryViewsInstallBackHandlers() {
        val app = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val scan = File("src/main/java/com/hawkeyexb/ppass/ui/ScanScreen.kt").readText()
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        assertTrue("顶层二级页面必须由系统返回 reducer 收敛", app.contains("systemBackTarget(screen)"))
        assertTrue("手动配对页必须先返回扫码页", scan.contains("BackHandler"))
        assertTrue("存储电脑详情必须先关闭详情页", home.contains("BackHandler"))
    }
}
