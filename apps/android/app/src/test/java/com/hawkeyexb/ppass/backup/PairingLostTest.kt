// 存储端移除/吊销设备后「配对已失效」判定（bug fix: android-repair-after-remote-revoke）:
// BackupRunner 的 check(resp.ok) 抛 IllegalStateException，消息携带 daemon 的
// msg_key——err.not_paired（设备行已删/从未配对）与 err.not_authorized（已吊销/
// 角色不允）都意味着配对关系失效，UI 应切「重新扫码连接」入口；其余失败
// （超时/网络/磁盘满）不算配对失效，保留正常重试。
// 生产调用链：BackupUiStateHolder.backupNow catch → isPairingLostError。
package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingLostTest {

    @Test
    fun notPairedMsgKeyFlagsPairingLost() {
        // BackupRunner.callOk 的真实消息形状（check 抛 IllegalStateException）。
        val t = IllegalStateException("backup.begin failed: err.not_paired")
        assertTrue("err.not_paired must flag pairing lost", isPairingLostError(t))
    }

    @Test
    fun notAuthorizedMsgKeyFlagsPairingLost() {
        val t = IllegalStateException("upload IMG_1.jpg rejected: err.not_authorized")
        assertTrue("err.not_authorized must flag pairing lost", isPairingLostError(t))
    }

    @Test
    fun msgKeyInsideLongerMessageStillFlags() {
        // 消息可能被包装/拼接（如 BackupUiStateHolder 的 take(140) 前的完整文本）。
        val t = IllegalStateException(
            "call to daemon failed: resp err.not_paired (node removed on storage side)"
        )
        assertTrue("msg_key inside a longer message must still flag", isPairingLostError(t))
    }

    @Test
    fun ordinaryFailuresDoNotFlagPairingLost() {
        // 反证：非配对门失败——超时/网络/磁盘满/通用错误，都不该切重新扫码。
        for (msg in listOf(
            "connection timed out after 5000ms",
            "connect failed: no route to host",
            "upload IMG_2.jpg rejected: err.disk_full",
            "backup.commit failed: err.backup_failed",
            "some generic failure",
        )) {
            assertFalse("must NOT flag pairing lost: $msg", isPairingLostError(IllegalStateException(msg)))
        }
    }

    @Test
    fun blankOrNullMessageDoesNotFlag() {
        assertFalse("empty message must not flag", isPairingLostError(IllegalStateException("")))
        assertFalse("null message must not flag", isPairingLostError(IllegalStateException(null as String?)))
    }
}
