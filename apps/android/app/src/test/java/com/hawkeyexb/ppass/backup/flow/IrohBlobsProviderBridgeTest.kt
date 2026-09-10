package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Test

class IrohBlobsProviderBridgeTest {
    @Test
    fun `register exposes only the item in the current epoch and active lease`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { sourceRef -> "fd:$sourceRef" }
        val epoch = PairingEpoch("desktop-b")
        val lease = FetchLease(queueSequence = 7L, leaseToken = "lease-7")
        val allowed = item(queueSequence = 7L, epoch = epoch)

        bridge.register(allowed, epoch, lease)

        assertEquals(listOf("${hashFor(7L)}:fd:content://media/7"), native.registrations)
        assertIllegalArgument {
            bridge.register(item(queueSequence = 8L, epoch = epoch), epoch, lease)
        }
        assertIllegalArgument {
            bridge.register(item(queueSequence = 7L, epoch = PairingEpoch("desktop-old")), epoch, lease)
        }
        assertEquals(listOf("${hashFor(7L)}:fd:content://media/7"), native.registrations)
    }

    @Test
    fun `pause stops the active native fetch then revokes its provider`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { sourceRef -> "fd:$sourceRef" }
        val epoch = PairingEpoch("desktop-b")
        val lease = FetchLease(queueSequence = 7L, leaseToken = "lease-7")
        bridge.register(item(queueSequence = 7L, epoch = epoch), epoch, lease)

        assertIllegalArgument {
            bridge.pause(FetchLease(queueSequence = 7L, leaseToken = "stale-lease"))
        }
        assertEquals(emptyList<String>(), native.events)
        bridge.pause(lease)

        assertEquals(listOf("stop:7", "revoke:${hashFor(7L)}"), native.events)
    }

    @Test
    fun `releaseRetention drops retention without revoking and verifies the lease`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { sourceRef -> "fd:$sourceRef" }
        val epoch = PairingEpoch("desktop-b")
        val lease = FetchLease(queueSequence = 7L, leaseToken = "lease-7")
        bridge.register(item(queueSequence = 7L, epoch = epoch), epoch, lease)

        assertIllegalArgument {
            bridge.releaseRetention(FetchLease(queueSequence = 7L, leaseToken = "stale-lease"))
        }
        assertEquals(emptyList<String>(), native.events)

        bridge.releaseRetention(lease)
        assertEquals(listOf("release:${hashFor(7L)}"), native.events)
    }

    @Test
    fun `next completed item keeps the native endpoint alive`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { sourceRef -> "fd:$sourceRef" }
        val epoch = PairingEpoch("desktop-b")
        bridge.register(item(queueSequence = 7L, epoch = epoch), epoch, FetchLease(7L, "lease-7"))
        bridge.register(item(queueSequence = 8L, epoch = epoch), epoch, FetchLease(8L, "lease-8"))

        assertEquals(emptyList<String>(), native.events)
        assertEquals(
            listOf(
                "${hashFor(7L)}:fd:content://media/7",
                "${hashFor(8L)}:fd:content://media/8",
            ),
            native.registrations,
        )
    }

    private inline fun assertIllegalArgument(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("expected IllegalArgumentException")
    }

    private fun hashFor(queueSequence: Long) = queueSequence.toString(16).padStart(64, '0')

    private fun item(queueSequence: Long, epoch: PairingEpoch) = TransferItem(
        stableId = "media-$queueSequence",
        sourceRef = "content://media/$queueSequence",
        sourceVersion = "1",
        bucketId = 1L,
        scopeRevision = ScopeRevision(),
        queueSequence = queueSequence,
        deliveryState = DeliveryState.QUEUED,
        contentHash = hashFor(queueSequence),
        pairingEpoch = epoch,
    )

    private class RecordingNativeProvider : NativeIrohBlobsProvider {
        val registrations = mutableListOf<String>()
        val events = mutableListOf<String>()

        override fun register(hash: String, source: Any): String {
            registrations += "$hash:$source"
            return "ticket:$hash"
        }

        override fun stopActiveFetch(queueSequence: Long) {
            events += "stop:$queueSequence"
        }

        override fun releaseRetention(hash: String) {
            events += "release:$hash"
        }

        override fun revoke(hash: String) {
            events += "revoke:$hash"
        }
    }
}
