package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.FileNotFoundException

class AndroidMediaImporterTest {
    private val hash = "ab".repeat(32)

    @Test
    fun `unopenable source is SourceMissing and never reaches native`() {
        val native = FakeNative()
        val bridge = IrohBlobsProviderBridge(native) { error("legacy path unused") }
        for (open in listOf<(String) -> AutoCloseable?>(
            { null },
            { throw FileNotFoundException("gone") },
            { throw SourceMissingException() },
        )) {
            assertEquals(ImportResult.SourceMissing, AndroidMediaImporter(bridge, open).import(1L, "content://media/1", "/p"))
        }
        assertEquals(emptyList<String>(), native.calls)
    }

    @Test
    fun `import passes path and descriptor, closes it on return, and reports the result`() {
        val native = FakeNative(importJson = """{"hash":"$hash","size":42,"by_reference":true,"fallback":null,"detail":null}""")
        val source = Source()
        val importer = AndroidMediaImporter(IrohBlobsProviderBridge(native) { error("unused") }, { source })

        val result = importer.import(7L, "content://media/7", "/storage/emulated/0/DCIM/a.jpg")

        assertEquals(ImportResult.Imported(hash, 42L, byReference = true), result)
        assertEquals(listOf("import:/storage/emulated/0/DCIM/a.jpg:$source"), native.calls)
        assertTrue(source.closed)
    }

    @Test
    fun `copy fallback is logged, not silent`() {
        val native = FakeNative(importJson = """{"hash":"$hash","size":9,"by_reference":false,"fallback":"no_path","detail":null}""")
        val logs = mutableListOf<String>()
        val importer = AndroidMediaImporter(IrohBlobsProviderBridge(native) { error("unused") }, { Source() }, FlowLogger { logs += it })

        assertEquals(ImportResult.Imported(hash, 9L, byReference = false), importer.import(3L, "content://media/3", null))
        assertEquals("import:null", native.calls.single().substringBeforeLast(':'))
        assertTrue(logs.single(), logs.single().contains("fallback=no_path"))
    }

    @Test
    fun `descriptor is closed when native import fails`() {
        val native = FakeNative(importFailure = IllegalStateException("store broken"))
        val source = Source()
        val importer = AndroidMediaImporter(IrohBlobsProviderBridge(native) { error("unused") }, { source })
        try {
            importer.import(1L, "content://media/1", "/p")
            fail("expected the native failure to propagate")
        } catch (_: IllegalStateException) {
        }
        assertTrue(source.closed)
    }

    @Test
    fun `serve makes the lease active and maps a gone original to SourceMissingException`() {
        val native = FakeNative()
        val bridge = IrohBlobsProviderBridge(native) { error("unused") }
        val importer = AndroidMediaImporter(bridge, { Source() })
        val lease = ProviderLease(5L, leaseTokenFor(5L), hash)

        assertEquals("ticket:$hash", importer.serve(lease))
        assertEquals(TransferStatus.InProgress(connected = false, idleForMs = null, source = SourceFault.CHANGED), bridge.transferStatus())

        native.serveFailure = FileNotFoundException("referenced source missing")
        try {
            importer.serve(lease)
            fail("expected SourceMissingException")
        } catch (_: SourceMissingException) {
        }
    }

    @Test
    fun `release never throws`() {
        val native = FakeNative(releaseFailure = IllegalStateException("unknown handle"))
        val logs = mutableListOf<String>()
        AndroidMediaImporter(IrohBlobsProviderBridge(native) { error("unused") }, { Source() }, FlowLogger { logs += it }).release(hash)
        assertEquals(listOf("release:$hash"), native.calls)
        assertEquals(1, logs.size)
    }

    @Test
    fun `transfer status carries the source fault`() {
        assertEquals(TransferStatus.Aborted(hash, SourceFault.MISSING), parseTransferStatus("""{"state":"aborted","hash":"$hash","source":"missing"}"""))
        assertEquals(TransferStatus.Aborted(hash), parseTransferStatus("""{"state":"aborted","hash":"$hash"}"""))
    }

    private class Source : AutoCloseable {
        var closed = false
        override fun close() {
            closed = true
        }
    }

    private class FakeNative(
        private val importJson: String = "{}",
        private val importFailure: Exception? = null,
        private val releaseFailure: Exception? = null,
    ) : NativeIrohBlobsProvider {
        val calls = mutableListOf<String>()
        var serveFailure: Exception? = null

        override fun importMedia(dataPath: String?, source: Any): String {
            calls += "import:$dataPath:$source"
            importFailure?.let { throw it }
            return importJson
        }

        override fun serve(hash: String): String {
            serveFailure?.let { throw it }
            return "ticket:$hash"
        }

        override fun release(hash: String) {
            calls += "release:$hash"
            releaseFailure?.let { throw it }
        }

        override fun register(hash: String, source: Any): String = error("legacy register unused")
        override fun stopActiveFetch(queueSequence: Long) = Unit
        override fun releaseRetention(hash: String) = Unit
        override fun revoke(hash: String) = Unit
        override fun transferStatus(): String = """{"state":"in_progress","connected":false,"source":"changed"}"""
    }
}
