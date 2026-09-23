package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Test

class IrohBlobsProviderBridgeTest {
    @Test
    fun `register imports exactly the leased order's source under its declared hash`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { uri -> "fd:$uri" }

        val ticket = bridge.register(lease(7L), "content://media/7")

        assertEquals("ticket:${hashFor(7L)}", ticket)
        assertEquals(listOf("${hashFor(7L)}:fd:content://media/7"), native.registrations)
        assertIllegalArgument { bridge.register(ProviderLease(8L, leaseTokenFor(8L), "not-a-hash"), "content://media/8") }
        assertEquals(1, native.registrations.size)
    }

    @Test
    fun `pause stops the active native fetch then revokes, a stale lease is a no-op`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { uri -> "fd:$uri" }
        bridge.register(lease(7L), "content://media/7")

        bridge.pause(ProviderLease(7L, "stale-lease", hashFor(7L)))
        assertEquals(emptyList<String>(), native.events)
        bridge.pause(lease(7L))
        assertEquals(listOf("stop:7", "revoke:${hashFor(7L)}"), native.events)
        assertEquals(TransferStatus.NoLease, bridge.transferStatus())
    }

    @Test
    fun `releaseRetention drops retention without revoking and verifies the lease`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { uri -> "fd:$uri" }
        bridge.register(lease(7L), "content://media/7")

        assertIllegalArgument { bridge.releaseRetention(ProviderLease(7L, "stale-lease", hashFor(7L))) }
        assertEquals(emptyList<String>(), native.events)
        bridge.releaseRetention(lease(7L))
        assertEquals(listOf("release:${hashFor(7L)}"), native.events)
    }

    @Test
    fun `next order keeps the native endpoint alive`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native) { uri -> "fd:$uri" }
        bridge.register(lease(7L), "content://media/7")
        bridge.register(lease(8L), "content://media/8")

        assertEquals(emptyList<String>(), native.events)
        assertEquals(listOf("${hashFor(7L)}:fd:content://media/7", "${hashFor(8L)}:fd:content://media/8"), native.registrations)
    }

    @Test
    fun `network change is forwarded to the native endpoint`() {
        val native = RecordingNativeProvider()
        IrohBlobsProviderBridge(native) { it }.networkChange()
        assertEquals(listOf("network_change"), native.events)
    }

    private inline fun assertIllegalArgument(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("expected IllegalArgumentException")
    }

    private fun hashFor(orderId: Long) = orderId.toString(16).padStart(64, '0')

    private fun lease(orderId: Long) = ProviderLease(orderId, leaseTokenFor(orderId), hashFor(orderId))

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

        override fun transferStatus(): String = "{\"state\":\"no_lease\"}"

        override fun networkChange() {
            events += "network_change"
        }
    }
}
