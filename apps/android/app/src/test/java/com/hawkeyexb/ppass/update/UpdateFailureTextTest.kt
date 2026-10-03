// UPD-02: 失败类 → 用户文案映射的完备性与互异性锁。
// 完备性：UpdateFailureKind 新增成员而 failureTextRes 没跟上，when 不再
// 穷尽直接编译红；这里再钉一层「7 类、类类有文案、文案不撞车」——
// 两类失败共用一句话，用户就无法区分「网络坏了」和「包被改过」。
package com.hawkeyexb.ppass.update

import com.hawkeyexb.ppass.R
import org.junit.Assert.assertEquals
import org.junit.Test

class UpdateFailureTextTest {

    @Test
    fun everyKindHasText() {
        assertEquals(7, UpdateFailureKind.entries.size)
        for (kind in UpdateFailureKind.entries) {
            failureTextRes(kind) // when 穷尽性：漏一个分支这里编译期就红
        }
    }

    @Test
    fun textsAreAllDistinct() {
        val texts = UpdateFailureKind.entries.map { failureTextRes(it) }
        assertEquals(texts.size, texts.toSet().size)
    }

    @Test
    fun mappingIsTheIntendedOne() {
        val expected = mapOf(
            UpdateFailureKind.Network to R.string.update_failed_network,
            UpdateFailureKind.Server to R.string.update_failed_server,
            UpdateFailureKind.Stalled to R.string.update_failed_stalled,
            UpdateFailureKind.Write to R.string.update_failed_write,
            UpdateFailureKind.Verify to R.string.update_failed_verify,
            UpdateFailureKind.Install to R.string.update_failed_install,
            UpdateFailureKind.Unexpected to R.string.update_failed_unexpected,
        )
        for ((kind, res) in expected) {
            assertEquals(kind.name, res, failureTextRes(kind))
        }
    }
}
