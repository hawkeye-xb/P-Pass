package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingId
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB64RevokedFlowDeliveryTest {
    @Test
    fun notPairedFlowDeliverySetsTheHolderPairingLostFlag() {
        val pid = PairingId("paired-id")
        val deliveryLoss = FlowDeliveryPairingLoss()
        val holderFlag = HolderPairingLostState()

        deliveryLoss.record(pid, com.hawkeyexb.ppass.backup.flow.DesktopRejectedException("not_paired", "flow.offer"))
        holderFlag.syncFrom(deliveryLoss, pid)

        assertTrue("not_paired delivery must show the existing pairing-lost card", holderFlag.value.value)
    }

    @Test
    fun notAuthorizedFlowDeliverySetsTheHolderPairingLostFlag() {
        val pid = PairingId("paired-id")
        val deliveryLoss = FlowDeliveryPairingLoss()
        val holderFlag = HolderPairingLostState()

        // Real Samsung revoke returns this at hello before any Flow offer/fetch.
        deliveryLoss.record(pid, com.hawkeyexb.ppass.backup.flow.DesktopRejectedException("not_paired", "hello"))
        holderFlag.syncFrom(deliveryLoss, pid)

        assertTrue("rejected hello must show the existing pairing-lost card", holderFlag.value.value)
    }

    @Test
    fun ordinaryDeliveryFailureDoesNotSetTheHolderPairingLostFlag() {
        val pid = PairingId("paired-id")
        val deliveryLoss = FlowDeliveryPairingLoss()
        val holderFlag = HolderPairingLostState()

        deliveryLoss.record(pid, IllegalStateException("flow.fetch: err.backup_failed"))
        holderFlag.syncFrom(deliveryLoss, pid)

        assertFalse("ordinary delivery failures must retain normal retry semantics", holderFlag.value.value)
    }
}
