// FIX-T6 验收①：空集 = 一个都不备——scanSince 返回空、countAll 返回 0，
// 并且**不发查询**（JVM 单测注入 null resolver：空集分支在触碰
// resolver 之前就返回；若守卫被删，空集路径会去 resolver.query →
// NPE → 测试必红，这就是反证）。
package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Test

class MediaScannerScopeTest {

    // null resolver 仅在「不发查询」被验证时可用——空集分支短路在
    // resolver 使用之前。非空集路径触碰 resolver（JVM 下抛 NPE），
    // 恰好证明空集结果来自守卫而非查询。
    private val scanner = MediaScanner(null)

    @Test
    fun empty_scope_scan_returns_empty_and_keeps_watermark() {
        val result = scanner.scanSince(watermark = 1234L, bucketIds = emptySet())
        assertEquals("空集 → 没有 items", 0, result.items.size)
        assertEquals("空集 → 水位不推进", 1234L, result.nextWatermark)
    }

    @Test
    fun empty_scope_count_is_zero() {
        assertEquals("空集 → countAll = 0", 0L, scanner.countAll(emptySet()))
    }

    @Test
    fun null_scope_still_means_full_scan_path() {
        // null（从未选范围）= 全量：守卫不短路，走真实查询路径
        // （null resolver 在 JVM 下必然抛——证明 null ≠ 空集，
        // 语义区分在守卫里，不在查询里）。
        val threw = runCatching { scanner.scanSince(0L, null) }.isFailure
        assertEquals("null 范围必须走查询路径（非空集守卫）", true, threw)
        val threwCount = runCatching { scanner.countAll(null) }.isFailure
        assertEquals("null 范围 countAll 走查询路径", true, threwCount)
    }
}
