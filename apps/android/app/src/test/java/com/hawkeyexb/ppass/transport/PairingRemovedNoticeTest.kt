// #1219 V4：被拒即清理之后的一次性说明——真的清掉才记、活过断开清单、看过即清。
// 用真的 PairingStore、真的断开清单执行器；唯一替身是运行时记账（DisconnectRuntime）。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.DisconnectRuntime
import com.hawkeyexb.ppass.backup.PairingRemovedNoticeStore
import com.hawkeyexb.ppass.backup.applyDisconnectManifest
import com.hawkeyexb.ppass.backup.flow.DesktopRejectedException
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingId
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PairingRemovedNoticeTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var filesDir: File
    private lateinit var cacheDir: File
    private lateinit var notice: PairingRemovedNoticeStore
    private val loss = FlowDeliveryPairingLoss()
    private val pairing = Pairing(daemonNodeId = "d".repeat(64), daemonAddrToken = "t", storageDeviceName = "Home", pairingId = "e1")

    private object NoRuntime : DisconnectRuntime {
        override fun stopFlowRuntime() = Unit
        override fun cancelUniqueWork(name: String) = Unit
        override fun cancelMediaWatch() = Unit
        override fun clearPreviewCache() = Unit
    }

    @Before
    fun setUp() {
        val data = tmp.newFolder("data")
        filesDir = File(data, "files").apply { mkdirs() }
        cacheDir = File(data, "cache").apply { mkdirs() }
        notice = PairingRemovedNoticeStore(filesDir)
        PairingStore(filesDir).save(pairing)
    }

    private fun cleanup(clear: (Pairing) -> Unit) = PairingRejectionCleanup(
        currentPairing = { PairingStore(filesDir).load() },
        loss = loss,
        clear = clear,
        recordNotice = { notice.record(it.pairingId) },
    )

    @Test
    fun rejectedAndCleared_leavesANoticeThatSurvivesTheManifest() {
        val c = cleanup { applyDisconnectManifest(filesDir, cacheDir, NoRuntime) }
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.fetch"))
        assertTrue(c.onLossRecorded())
        assertTrue("说明要活过断开清单", notice.pending())
        // 再跑一遍清单（比如之后用户手动走一次断开路径）也不能把待说明删掉。
        applyDisconnectManifest(filesDir, cacheDir, NoRuntime)
        assertTrue(notice.pending())
        notice.clear()
        assertFalse("看过即清", notice.pending())
    }

    @Test
    fun clearFailed_noNotice() {
        // 配对记录没删掉（写盘失败）——界面不能以为已经断开，也不能说明「已移除」。
        val c = cleanup { }
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.fetch"))
        assertFalse(c.onLossRecorded())
        assertFalse(notice.pending())
    }

    @Test
    fun staleRejection_forAnOldPairing_noNotice() {
        val c = cleanup { applyDisconnectManifest(filesDir, cacheDir, NoRuntime) }
        loss.record(PairingId("old"), DesktopRejectedException("not_paired", "flow.fetch"))
        assertFalse(c.onLossRecorded())
        assertFalse(notice.pending())
    }
}
