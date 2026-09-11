package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB64RevokedFlowDeliveryTest {
    @Test
    fun notPairedFlowDeliverySetsTheHolderPairingLostFlag() {
        val epoch = PairingEpoch("paired-epoch")
        val deliveryLoss = FlowDeliveryPairingLoss()
        val holderFlag = HolderPairingLostState()

        deliveryLoss.record(epoch, IllegalStateException("flow.offer: err.not_paired"))
        holderFlag.syncFrom(deliveryLoss, epoch)

        assertTrue("ERR_NOT_PAIRED delivery must show the existing pairing-lost card", holderFlag.value.value)
    }

    @Test
    fun notAuthorizedFlowDeliverySetsTheHolderPairingLostFlag() {
        val epoch = PairingEpoch("paired-epoch")
        val deliveryLoss = FlowDeliveryPairingLoss()
        val holderFlag = HolderPairingLostState()

        // Real Samsung revoke returns this at hello before any Flow offer/fetch.
        deliveryLoss.record(epoch, IllegalStateException("hello: err.not_authorized"))
        holderFlag.syncFrom(deliveryLoss, epoch)

        assertTrue("ERR_NOT_AUTHORIZED delivery must show the existing pairing-lost card", holderFlag.value.value)
    }

    @Test
    fun ordinaryDeliveryFailureDoesNotSetTheHolderPairingLostFlag() {
        val epoch = PairingEpoch("paired-epoch")
        val deliveryLoss = FlowDeliveryPairingLoss()
        val holderFlag = HolderPairingLostState()

        deliveryLoss.record(epoch, IllegalStateException("flow.fetch: err.backup_failed"))
        holderFlag.syncFrom(deliveryLoss, epoch)

        assertFalse("ordinary delivery failures must retain normal retry semantics", holderFlag.value.value)
    }
}
