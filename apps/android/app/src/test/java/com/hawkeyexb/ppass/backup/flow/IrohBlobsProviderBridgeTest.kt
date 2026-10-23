package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Test

class IrohBlobsProviderBridgeTest {
    // importMedia 只导入、不供数；serve 才让它成为当前 lease 并出 ticket。
    @Test
    fun `import then serve leases exactly the order's content hash`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native)

        val imported = bridge.importMedia("/storage/a.jpg", "fd:7")
        assertEquals(hashFor(7L), imported.contentHash)
        assertEquals(listOf("import:/storage/a.jpg:fd:7"), native.calls)
        assertEquals("ticket:${hashFor(7L)}", bridge.serve(lease(7L)))
        assertEquals(listOf("import:/storage/a.jpg:fd:7", "serve:${hashFor(7L)}"), native.calls)
        assertIllegalArgument { bridge.serve(ProviderLease(8L, leaseTokenFor(8L), "not-a-hash")) }
        assertEquals(2, native.calls.size)
    }

    @Test
    fun `pause stops the active native fetch then revokes, a stale lease is a no-op`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native)
        bridge.serve(lease(7L))

        bridge.pause(ProviderLease(7L, "stale-lease", hashFor(7L)))
        assertEquals(emptyList<String>(), native.events)
        bridge.pause(lease(7L))
        assertEquals(listOf("stop:7", "revoke:${hashFor(7L)}"), native.events)
        assertEquals(TransferStatus.NoLease, bridge.transferStatus())
    }

    @Test
    fun `releaseRetention drops retention without revoking and verifies the lease`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native)
        bridge.serve(lease(7L))

        assertIllegalArgument { bridge.releaseRetention(ProviderLease(7L, "stale-lease", hashFor(7L))) }
        assertEquals(emptyList<String>(), native.events)
        bridge.releaseRetention(lease(7L))
        assertEquals(listOf("release:${hashFor(7L)}"), native.events)
    }

    @Test
    fun `next order keeps the native endpoint alive`() {
        val native = RecordingNativeProvider()
        val bridge = IrohBlobsProviderBridge(native)
        bridge.serve(lease(7L))
        bridge.serve(lease(8L))

        assertEquals(emptyList<String>(), native.events)
        assertEquals(listOf("serve:${hashFor(7L)}", "serve:${hashFor(8L)}"), native.calls)
    }

    @Test
    fun `network change is forwarded to the native endpoint`() {
        val native = RecordingNativeProvider()
        IrohBlobsProviderBridge(native).networkChange()
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

    private companion object {
        fun hashFor(orderId: Long) = orderId.toString(16).padStart(64, '0')
    }

    private fun lease(orderId: Long) = ProviderLease(orderId, leaseTokenFor(orderId), hashFor(orderId))

    private class RecordingNativeProvider : NativeIrohBlobsProvider {
        /** 导入 / 供数（准备 lease 的调用）；[events] 只记停止、放手、网络变化这类动作。 */
        val calls = mutableListOf<String>()
        val events = mutableListOf<String>()

        override fun importMedia(dataPath: String?, source: Any): NativeMediaImport {
            calls += "import:$dataPath:$source"
            return NativeMediaImport(hashFor(7L), 1, byReference = true)
        }

        override fun serve(hash: String): String {
            calls += "serve:$hash"
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

        override fun transferStatus(): TransferStatus = TransferStatus.NoLease

        override fun networkChange() {
            events += "network_change"
        }
    }
}
