// #793: 用户在系统任一层（「安装未知应用」授权页 / 「不允许此来源」门 / 安装确认页）离开，
// App 都要如实回到「可以安装」，不许停在「正在安装…」。
//
// 本质：系统弹窗的结果 App 必须如实反映。标准做法（Android 官方）：
//  1. 提交安装会话前先查 canRequestPackageInstalls()，没有授权先带去授权页；
//  2. 回到前台时对账「正在安装」：以系统安装会话为准——会话已不存在、仍无回执 = 这次没装；
//     会话还在就继续等（#828，见 UPD828InstallSessionTruthTest）。
package com.hawkeyexb.ppass.update

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UPD793InstallReturnTest {

    private val ready = UpdateUiState.ReadyToInstall("0.9.12")
    private val installing = UpdateUiState.Installing("0.9.12")

    /**
     * 反证：去掉 ReconcileInstalling 分支（= 回到前台不对账）→ 第一条红：
     * 这正是 #793 的现场——会话没了、回执不来，界面一直「正在安装」。
     */
    @Test
    fun comingBackWhileInstallingWithTheSessionGoneIsReconciled() {
        assertEquals(ResumeInstallAction.ReconcileInstalling, resumeInstallAction(installing, false, true, false))
        assertEquals(ResumeInstallAction.ReconcileInstalling, resumeInstallAction(installing, false, false, false))
    }

    @Test
    fun comingBackFromThePermissionPageContinuesOnlyWhenGranted() {
        assertEquals("授权了：接着装（用户本来就是要装）", ResumeInstallAction.ContinueInstall, resumeInstallAction(ready, true, true, false))
        assertEquals("没授权：停在可以安装", ResumeInstallAction.StayReady, resumeInstallAction(ready, true, false, false))
        assertEquals("没去过授权页：不自作主张去装", ResumeInstallAction.None, resumeInstallAction(ready, false, true, false))
        assertEquals(ResumeInstallAction.None, resumeInstallAction(UpdateUiState.Idle, false, true, false))
    }

    /** 反证：把授权预检挪到 installJob 之后（或删掉）→ 红。 */
    @Test
    fun installChecksPermissionBeforeCommittingASession() {
        val src = File("src/main/java/com/hawkeyexb/ppass/update/UpdateUiController.kt").readText()
        val body = src.substringAfter("fun onUserInstall()").substringBefore("\n    }\n")
        val check = body.indexOf("UpdateInstaller.canInstall(context)")
        val commit = body.indexOf("UpdateInstaller.install(context, apk")
        assertTrue("onUserInstall 必须先查授权: $body", check >= 0)
        assertTrue("授权预检必须在提交安装会话之前", check < commit)
        assertTrue("没授权时带用户去授权页", body.contains("UpdateInstaller.installPermissionIntent(context)"))
    }

    /**
     * 回到前台对账会取消「等回执」的协程。取消必须照协程约定抛回去，不能被 `catch (e: Exception)`
     * 吞成「安装失败」（三星实测：吞掉时界面变成「更新没有完成」而不是「可以安装」）。
     * 反证：删掉 CancellationException 分支 → 红。
     */
    @Test
    fun cancellationWhileAwaitingTheResultIsNotReportedAsAFailure() {
        val src = File("src/main/java/com/hawkeyexb/ppass/update/UpdateInstaller.kt").readText()
        val body = src.substringAfter("session.commit(pendingIntent.intentSender)")
        val cancel = body.indexOf("catch (e: CancellationException)")
        val generic = body.indexOf("catch (e: Exception)")
        assertTrue("提交后的等待必须单独处理取消", cancel >= 0)
        assertTrue("取消分支必须在通用 Exception 分支之前", cancel < generic)
        assertTrue("取消要抛回去", body.substring(cancel, generic).contains("throw e"))
    }
}
