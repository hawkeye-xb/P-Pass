// 取原片时收到的字节超过电脑声明的大小：立即中止（只中止一次），并记下超出时的字节数。
package com.hawkeyexb.ppass.transport

import org.junit.Assert.assertEquals
import org.junit.Test

class DeclaredSizeGuardTest {

    @Test
    fun downloadAbortsWhenReceivedBytesExceedDeclaredSize() {
        var aborts = 0
        val guard = DeclaredSizeGuard(declared = 1_000) { aborts++ }
        guard.onBytes(400)
        guard.onBytes(1_000) // 正好等于声明大小：不中止
        assertEquals(0, aborts)
        assertEquals(-1L, guard.exceededAt)
        guard.onBytes(1_001)
        assertEquals(1, aborts)
        assertEquals(1_001L, guard.exceededAt)
        guard.onBytes(50_000) // 之后的回调不再重复中止
        assertEquals(1, aborts)
        assertEquals(1_001L, guard.exceededAt)
    }

    @Test
    fun downloadWithinDeclaredSizeIsNotAborted() {
        var aborts = 0
        val guard = DeclaredSizeGuard(declared = 1_000) { aborts++ }
        listOf(0L, 300L, 999L, 1_000L).forEach(guard::onBytes)
        assertEquals(0, aborts)
    }

    @Test
    fun oversizeIsNotACancellation() {
        // 超大中止必须作为真实失败显示出来，不能被当成「用户划走」静默吞掉。
        val e: Throwable = OriginalExceedsDeclaredSizeException(1_000, 1_001)
        assertEquals(false, e is kotlinx.coroutines.CancellationException)
    }
}
