package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.FileNotFoundException

class AndroidMediaImporterTest {
    private val hash = "ab".repeat(32)

    @Test
    fun `unopenable source is SourceMissing and never reaches native`() {
        val native = FakeNative()
        val bridge = IrohBlobsProviderBridge(native)
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
        val native = FakeNative(import = NativeMediaImport(hash, 42, byReference = true))
        val source = Source()
        val importer = AndroidMediaImporter(IrohBlobsProviderBridge(native), { source })

        val result = importer.import(7L, "content://media/7", "/storage/emulated/0/DCIM/a.jpg")

        assertEquals(ImportResult.Imported(hash, 42L, byReference = true), result)
        assertEquals(listOf("import:/storage/emulated/0/DCIM/a.jpg:$source"), native.calls)
        assertTrue(source.closed)
    }

    @Test
    fun `copy fallback is logged, not silent`() {
        val native = FakeNative(import = NativeMediaImport(hash, 9, byReference = false, fallback = "no_path"))
        val logs = mutableListOf<String>()
        val importer = AndroidMediaImporter(IrohBlobsProviderBridge(native), { Source() }, FlowLogger { logs += it })

        assertEquals(ImportResult.Imported(hash, 9L, byReference = false), importer.import(3L, "content://media/3", null))
        assertEquals("import:null", native.calls.single().substringBeforeLast(':'))
        assertTrue(logs.single(), logs.single().contains("fallback=no_path"))
    }

    @Test
    fun `descriptor is closed when native import fails`() {
        val native = FakeNative(importFailure = IllegalStateException("store broken"))
        val source = Source()
        val importer = AndroidMediaImporter(IrohBlobsProviderBridge(native), { source })
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
        val bridge = IrohBlobsProviderBridge(native)
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
        AndroidMediaImporter(IrohBlobsProviderBridge(native), { Source() }, FlowLogger { logs += it }).release(hash)
        assertEquals(listOf("release:$hash"), native.calls)
        assertEquals(1, logs.size)
    }

    // ---------------------------------------------------------------- #843 原样字节

    private val import843 = NativeMediaImport(hash, 42, byReference = true)

    private fun importer(readable: Boolean, opened: MutableList<String>, original: (String) -> AutoCloseable? = { opened += "original"; Source() }) =
        AndroidMediaImporter(
            IrohBlobsProviderBridge(FakeNative(import = import843)),
            open = { opened += "plain"; Source() },
            openOriginal = original,
            locationReadable = { readable },
        )

    // 有位置权限：按平台规定走 setRequireOriginal 那条打开路径，结果记「未抹」。
    // 反证：仍用普通打开 → opened == [plain]，红。
    @Test
    fun `with the location grant the importer opens the original and records it unredacted`() {
        val opened = mutableListOf<String>()
        val result = importer(readable = true, opened).import(1L, "content://media/1", "/p") as ImportResult.Imported
        assertEquals(listOf("original"), opened)
        assertFalse(result.locationRedacted)
    }

    // 没有位置权限：照常读（不打断备份），结果如实记「已抹」，不静默。
    // 反证：没权限也去开原图 → 系统抛 UnsupportedOperationException，或 locationRedacted 记 false，红。
    @Test
    fun `without the grant it reads the redacted bytes and says so`() {
        val opened = mutableListOf<String>()
        val result = importer(readable = false, opened).import(1L, "content://media/1", "/p") as ImportResult.Imported
        assertEquals(listOf("plain"), opened)
        assertTrue(result.locationRedacted)
    }

    // 检查时有权限、打开时被收回：系统抛 UnsupportedOperationException（三星 Android 15 实测）→ 按抹过的读，不失败。
    @Test
    fun `a grant revoked between check and open falls back to the redacted read`() {
        val opened = mutableListOf<String>()
        val result = importer(readable = true, opened, original = { throw UnsupportedOperationException("Caller must hold ACCESS_MEDIA_LOCATION") })
            .import(1L, "content://media/1", "/p") as ImportResult.Imported
        assertEquals(listOf("plain"), opened)
        assertTrue(result.locationRedacted)
    }

    private class Source : AutoCloseable {
        var closed = false
        override fun close() {
            closed = true
        }
    }

    private class FakeNative(
        private val import: NativeMediaImport = NativeMediaImport("00".repeat(32), 0, byReference = false),
        private val importFailure: Exception? = null,
        private val releaseFailure: Exception? = null,
    ) : NativeIrohBlobsProvider {
        val calls = mutableListOf<String>()
        var serveFailure: Exception? = null

        override fun importMedia(dataPath: String?, source: Any): NativeMediaImport {
            calls += "import:$dataPath:$source"
            importFailure?.let { throw it }
            return import
        }

        override fun serve(hash: String): String {
            serveFailure?.let { throw it }
            return "ticket:$hash"
        }

        override fun release(hash: String) {
            calls += "release:$hash"
            releaseFailure?.let { throw it }
        }

        override fun stopActiveFetch(queueSequence: Long) = Unit
        override fun releaseRetention(hash: String) = Unit
        override fun revoke(hash: String) = Unit
        override fun transferStatus(): TransferStatus = TransferStatus.InProgress(connected = false, idleForMs = null, source = SourceFault.CHANGED)
    }
}
