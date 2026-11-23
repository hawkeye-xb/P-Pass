// #1771：真实构造 ContentResolverMediaSnapshotSource（不是 FakeMedia 替身），验证「缺席不可信 → 回答不知道」。
// JVM 单测里 android.jar 的 Context / ContentResolver 只是 stub（方法一调就抛 "Stub!"），
// 所以用 MockK 替身这两个平台类，被测类本身真实实例化。
// 反证：删掉 existingIds 开头的 `if (!absenceTrusted()) return null` 后，前两条断言变红
// （空请求会返回空集、非空请求会去查 resolver）。
package com.hawkeyexb.ppass.backup.order

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ContentResolverMediaSnapshotSourceTest {

    private val resolver = mockk<ContentResolver>(relaxed = true)

    private fun source(absenceTrusted: Boolean): ContentResolverMediaSnapshotSource =
        ContentResolverMediaSnapshotSource(
            context = mockk<Context>(relaxed = true),
            scope = { null },
            resolver = resolver,
            absenceTrusted = { absenceTrusted },
        )

    // 非完整相册权限：查得到的是偏小集合，问到的 ID 一个都不能断言成「还在」，也不该白查一次。
    @Test
    fun `untrusted absence answers unknown for the asked ids`() {
        assertNull(source(absenceTrusted = false).existingIds(listOf(1L)))
        verify(exactly = 0) {
            resolver.query(any<Uri>(), any(), any(), any(), any())
        }
    }

    // 不可信就是不知道，与这次问没问 ID 无关——空请求同样不许回答空集。
    @Test
    fun `untrusted absence answers unknown even for an empty ask`() {
        assertNull(source(absenceTrusted = false).existingIds(emptyList()))
    }

    // 反证基准：同一空请求在缺席可信时回答空集，证明上一条的 null 来自权限判定而不是「没有 ID 可问」。
    @Test
    fun `trusted absence answers an empty set for an empty ask`() {
        assertEquals(emptySet<Long>(), source(absenceTrusted = true).existingIds(emptyList()))
    }
}
