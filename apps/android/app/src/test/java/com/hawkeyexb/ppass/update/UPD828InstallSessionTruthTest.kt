// #828: 安装结果以系统安装会话为准。#793 的「回到前台 1.5 秒无回执 = 没装」把仍在进行的会话
// 撤销了（三星发布签名包实测：点「更新」后 `Session was abandoned`，界面退回「可以安装」）。
//
// 本质：会话还活着 = 安装还在进行（等用户确认或系统在装），App 只能等，不能替系统下结论。
// 标准做法：回到前台时查 PackageInstaller.getSessionInfo(id)；会话已不存在且没有回执，
// 才退回「可以安装」。放弃会话只能来自用户的显式动作（「以后再说」）或新一次安装顶替。
package com.hawkeyexb.ppass.update

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UPD828InstallSessionTruthTest {

    private val ready = UpdateUiState.ReadyToInstall("0.9.12")
    private val installing = UpdateUiState.Installing("0.9.12")

    /** 反证：回到 #793 的判定（不看会话）→ 第一条红：这正是三星上被撤销的那次安装。 */
    @Test
    fun aLiveSessionIsNeverReconciledAway() {
        assertEquals(ResumeInstallAction.None, resumeInstallAction(installing, false, true, sessionAlive = true))
        assertEquals(ResumeInstallAction.None, resumeInstallAction(installing, false, false, sessionAlive = true))
    }

    @Test
    fun aGoneSessionWithoutAResultGoesBackToReady() {
        assertEquals(
            ResumeInstallAction.ReconcileInstalling,
            resumeInstallAction(installing, false, true, sessionAlive = false),
        )
    }

    @Test
    fun thePermissionReturnIsUnchanged() {
        assertEquals(ResumeInstallAction.ContinueInstall, resumeInstallAction(ready, true, true, sessionAlive = false))
        assertEquals(ResumeInstallAction.StayReady, resumeInstallAction(ready, true, false, sessionAlive = false))
        assertEquals(ResumeInstallAction.None, resumeInstallAction(ready, false, true, sessionAlive = false))
    }

    private val controller =
        File("src/main/java/com/hawkeyexb/ppass/update/UpdateUiController.kt").readText()

    /** 反证：对账延时到点后不再查会话就退回 → 红（会话可能在延时里刚被系统接管）。 */
    @Test
    fun theGraceTimerRechecksTheSessionBeforeGivingUp() {
        val body = controller.substringAfter("ResumeInstallAction.ReconcileInstalling ->")
            .substringBefore("ResumeInstallAction.StayReady")
        assertTrue("延时到点必须再查一次会话: $body", body.contains("installSessionAlive()"))
    }

    /** 反证：新一次安装不清旧会话 → 红（系统里会残留一个等确认的会话）。 */
    @Test
    fun aNewInstallReplacesTheStillAliveOldSession() {
        val body = controller.substringAfter("fun onUserInstall()").substringBefore("\n    }\n")
        val drop = body.indexOf("abandonInstallSession()")
        val commit = body.indexOf("UpdateInstaller.install(")
        assertTrue("onUserInstall 必须先放掉旧会话: $body", drop >= 0)
        assertTrue("放掉旧会话必须在提交新会话之前", drop < commit)
    }

    /** 「正在安装」弹窗必须有出口：Home 离开系统确认页时会话活着、没有终态，不能把用户卡住。 */
    @Test
    fun theInstallingDialogHasAWayBackAndAWayOut() {
        val dialog = File("src/main/java/com/hawkeyexb/ppass/ui/UpdateDialog.kt").readText()
        val body = dialog.substringAfter("is UpdateUiState.Installing ->")
            .substringBefore("UpdateUiState.Idle, UpdateUiState.Checking ->")
        assertTrue("要能重新打开系统确认页: $body", body.contains("onReopenInstall"))
        assertTrue("要能显式放弃: $body", body.contains("onGiveUpInstall"))
    }
}
