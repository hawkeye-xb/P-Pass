// #1126：上传 provider 改走 uniffi `Provider` 之后，Kotlin 侧只剩「uniffi 记录 → 领域类型」的映射与异常口径。
// 原来走 JSON 中转的语义要原样保住（对照提交 0a8ad1c4 之前的 android_wire.rs 的 import_wire / status_wire）：
//   - 导入结果：hash / size / by_reference / fallback 字串 / detail；
//   - 传输状态：`Completed` 不附带原图故障，`Aborted` / `InProgress` 附带；
//   - serve 遇到原图已删 / 已变 → FileNotFoundException（桥译成 SourceMissingException），其余 IllegalStateException。
//
// 反证（改坏哪里 → 哪条红）：映射里把 byReference 取反 / fallback 与 detail 对调 ⇒ `import record maps every field`；
// `Completed` 也附带故障 ⇒ `a completed pull never carries a source fault`；idleForMs 与 byteIdleForMs 对调 ⇒
// `in progress maps durations and byte counters`；providerFailure 不区分 SourceFault ⇒ `a gone original is FileNotFound`。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.ffi.FfiException
import com.hawkeyexb.ppass.ffi.MediaImport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.FileNotFoundException
import com.hawkeyexb.ppass.ffi.TransferStatus as Ffi

class NativeProviderMappingTest {
    private val hash = "ab".repeat(32)

    @Test
    fun `import record maps every field`() {
        assertEquals(
            NativeMediaImport(hash, 42L, byReference = true, fallback = null, detail = null),
            MediaImport(hash, 42UL, true, null, null).toNative(),
        )
        assertEquals(
            NativeMediaImport(hash, 9L, byReference = false, fallback = "no_path", detail = "why"),
            MediaImport(hash, 9UL, false, "no_path", "why").toNative(),
        )
    }

    @Test
    fun `a malformed import hash is rejected`() {
        try {
            MediaImport("abc", 1UL, true, null, null).toNative()
            fail("expected a malformed hash to be rejected")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `no lease and completed map straight through`() {
        assertEquals(TransferStatus.NoLease, mergeTransferStatus(Ffi.NoLease, null))
        assertEquals(TransferStatus.Completed(hash), mergeTransferStatus(Ffi.Completed(hash), null))
    }

    // 原 status_wire：已经拿到全部字节的拉取不带故障。
    @Test
    fun `a completed pull never carries a source fault`() {
        assertEquals(TransferStatus.Completed(hash), mergeTransferStatus(Ffi.Completed(hash), "missing"))
        assertEquals(TransferStatus.Completed(hash), mergeTransferStatus(Ffi.Completed(hash), "changed"))
    }

    @Test
    fun `aborted and in progress carry the source fault`() {
        assertEquals(TransferStatus.Aborted(hash, SourceFault.MISSING), mergeTransferStatus(Ffi.Aborted(hash), "missing"))
        assertEquals(TransferStatus.Aborted(hash, SourceFault.CHANGED), mergeTransferStatus(Ffi.Aborted(hash), "changed"))
        assertEquals(TransferStatus.Aborted(hash), mergeTransferStatus(Ffi.Aborted(hash), null))
        val progress = Ffi.InProgress(connected = false, idleForMs = null, bytesSent = null, byteIdleForMs = null)
        assertEquals(
            TransferStatus.InProgress(connected = false, idleForMs = null, source = SourceFault.CHANGED),
            mergeTransferStatus(progress, "changed"),
        )
    }

    @Test
    fun `an unknown fault string is no fault`() {
        assertEquals(TransferStatus.Aborted(hash), mergeTransferStatus(Ffi.Aborted(hash), "something_new"))
    }

    @Test
    fun `in progress maps durations and byte counters`() {
        assertEquals(
            TransferStatus.InProgress(connected = true, idleForMs = 5L, bytesSent = 4096L, byteIdleForMs = 180_000L),
            mergeTransferStatus(Ffi.InProgress(connected = true, idleForMs = 5UL, bytesSent = 4096UL, byteIdleForMs = 180_000UL), null),
        )
    }

    @Test
    fun `a gone original is FileNotFound and everything else IllegalState`() {
        val gone = FfiException.SourceFault("missing")
        val failure = providerFailure(gone)
        assertTrue(failure is FileNotFoundException)
        assertSame(gone, failure.cause)
        for (other in listOf(FfiException.NotImported(hash), FfiException.Transport("x"), FfiException.InvalidArgument("x"))) {
            val mapped = providerFailure(other)
            assertTrue("$other", mapped is IllegalStateException)
            assertSame(other, mapped.cause)
        }
    }
}
