// #835：自我更新按平台标准请求免确认（PackageInstaller.SessionParams.setRequireUserAction）。
// 平台条件（Android 15）：已获 REQUEST_INSTALL_PACKAGES、更新自己、目标 SDK ≥ 33、声明
// UPDATE_PACKAGES_WITHOUT_USER_ACTION。少任何一条，系统都会退回弹确认页——所以两处都要锁住。
package com.hawkeyexb.ppass.update

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class UPD835SilentSelfUpdateTest {

    /** 反证：删掉 setRequireUserAction → 红。 */
    @Test
    fun theSessionAsksForNoUserAction() {
        val src = File("src/main/java/com/hawkeyexb/ppass/update/UpdateInstaller.kt").readText()
        val create = src.substringAfter("fun install(").substringBefore("installer.createSession(params)")
        assertTrue("会话建立前必须请求免确认: $create", create.contains("USER_ACTION_NOT_REQUIRED"))
    }

    /** 反证：删掉清单里的权限 → 红（Android 14+ 没有它就一律弹确认页）。 */
    @Test
    fun theManifestDeclaresThePermission() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION"))
    }
}
