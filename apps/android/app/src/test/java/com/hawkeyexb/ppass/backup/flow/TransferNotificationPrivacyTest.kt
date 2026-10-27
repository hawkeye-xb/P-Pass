// #1152（MASWE-0037）：传输前台通知用系统的锁屏隐私机制——VISIBILITY_PRIVATE + publicVersion。
// 锁屏上只有标题和进度，不含文件名；解锁后照常显示文件名，用户自己的锁屏通知设置同样生效。
//
// 反证：publicText 改成 privateText ⇒ 第一条红；builder 去掉 setVisibility / setPublicVersion，或锁屏版引用了
// 文件名那一份文案 ⇒ 第二条红。（Notification 本身要 Android 运行时，JVM 单测断言的是纯函数 + builder 的接线。）
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferNotificationPrivacyTest {
    private val title = "Backing up photos"

    @Test
    fun `the lock screen text never carries the file name, the unlocked text does`() {
        val status = LoopStatus(LoopPhase.RUNNING, CurrentItem(orderId = 1, fileName = "IMG_0042.HEIC", bytesSent = 250, totalBytes = 1000))
        val parts = transferNotificationParts(title, status)
        assertEquals("IMG_0042.HEIC", parts.privateText)
        assertEquals(title, parts.publicText)
        assertFalse(parts.publicText.contains("IMG_0042"))
        assertEquals(250, parts.permille)
        assertFalse(parts.indeterminate)
    }

    @Test
    fun `without a current item both versions fall back to the title and there is no progress bar`() {
        val parts = transferNotificationParts(title, LoopStatus(LoopPhase.RUNNING))
        assertEquals(title, parts.privateText)
        assertEquals(title, parts.publicText)
        assertNull(parts.permille)
        assertFalse(parts.indeterminate)
    }

    @Test
    fun `a current item without byte totals shows an indeterminate bar`() {
        val parts = transferNotificationParts(title, LoopStatus(LoopPhase.RUNNING, CurrentItem(1, "a.jpg", 0, 0)))
        assertTrue(parts.indeterminate)
    }

    @Test
    fun `the notification is private and carries a public version built from the file-name-free text`() {
        val src = File("src/main/java/com/hawkeyexb/ppass/backup/flow/FlowTransferForegroundService.kt").readText()
        val builder = src.substringAfter("internal fun buildTransferNotification").substringBefore("class FlowTransferForegroundService")
        assertTrue(builder.contains(".setVisibility(NotificationCompat.VISIBILITY_PRIVATE)"))
        assertTrue(builder.contains(".setPublicVersion(lockScreenVersion)"))
        val lockScreen = builder.substringAfter("val lockScreenVersion").substringBefore(".build()")
        assertTrue(lockScreen.contains("parts.publicText"))
        assertFalse("the lock-screen version must not touch the file-name text", lockScreen.contains("privateText"))
    }
}
