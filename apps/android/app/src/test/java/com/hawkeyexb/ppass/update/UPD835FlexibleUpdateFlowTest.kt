// #835：按 Google Play 应用内更新「灵活更新」的标准收敛弹窗——问一次、后台下载、下完提示一次。
// 用户在「发现新版本」上点过「下载安装」就是全部的意思表示：下载进度不再顶一个对话框在面前，
// 只有终态（下完 / 失败）才回到用户面前；想看进度点设置里的「检查更新」行。
package com.hawkeyexb.ppass.update

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class UPD835FlexibleUpdateFlowTest {

    private val src = File("src/main/java/com/hawkeyexb/ppass/update/UpdateUiController.kt").readText()

    private fun body(of: String) = src.substringAfter("fun $of(").substringBefore("\n    }\n")

    /** 反证：确认下载后把压制设回 false（弹进度框）→ 红。 */
    @Test
    fun confirmingTheDownloadGoesStraightToTheBackground() {
        val b = body("onUserConfirmDownload")
        assertTrue("确认下载后直接后台进行: $b", b.contains("dialogSuppressed.value = true"))
        assertTrue("确认下载后不得弹进度框: $b", !b.contains("dialogSuppressed.value = false"))
    }

    /** 反证：下载失败后「重试」又把进度框顶出来 → 红。 */
    @Test
    fun retryingADownloadAlsoStaysInTheBackground() {
        val b = body("onUserRetry")
        assertTrue("重试下载同样后台进行: $b", b.contains("dialogSuppressed.value = true"))
    }

    /** 终态必须回到用户面前（原有约定，锁住不退化）。 */
    @Test
    fun readyAndFailedStillReachTheUser() {
        val observe = src.substringAfter("private fun observeWorker()").substringBefore("// ── 触发节点")
        assertTrue(observe.contains("reduced is UpdateUiState.Failed || reduced is UpdateUiState.ReadyToInstall"))
        assertTrue(observe.contains("dialogSuppressed.value = false"))
    }
}
