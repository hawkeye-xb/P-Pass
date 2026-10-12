// #843：照片的拍摄地点——读原样字节、如实记录是否被抹、拿到权限不翻旧账也不漏传。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LOC843OriginalBytesTest {
    // 新建的 order 行记下这次读到的字节是否抹过地点（给「用原图替换旧副本」用的事实）。
    @Test
    fun `a new order records whether its bytes were location-redacted`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.importer.locationRedacted = true
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertTrue(rig.store.currentForMedia(1)!!.locationRedacted)

        rig.photo(2, generation = 2)
        rig.importer.locationRedacted = false
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.store.currentForMedia(2)!!.locationRedacted)
        rig.close()
    }

    // 拿到权限后，已经确认的旧照片**不重读、不重传**：否则同一张照片在桌面多出一份（指纹不同，桌面不认识）。
    // 用原图替换旧副本是单独一张卡，要桌面配合核对。反证：版本身份里带上读法 → 全部旧照片重新导入，imported 非空，红。
    @Test
    fun `already confirmed photos are not re-read when the grant appears`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        rig.importer.locationRedacted = true
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        val before = rig.importer.imported.size

        rig.importer.locationRedacted = false
        rig.importer.hashOverride[p.mediaId] = "blake3:original-with-gps"
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        rig.trigger(TriggerReason.PERIODIC)

        assertEquals(before, rig.importer.imported.size)
        assertEquals(1, rig.delivery.requests.size)
        rig.close()
    }

    // 升级那一刻还在路上的照片：拿到权限后重新导入读到原样字节（hash 变了）→ 旧行结掉、新行带原样字节传完，不漏。
    // 反证：#843 之前的处理（只结旧行）→ 这张照片永远不传，requests 为空，红。
    @Test
    fun `a photo in flight when the grant appears is delivered with its original bytes`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val old = rig.order(p, OrderState.TRANSFERRING)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        rig.importer.hashOverride[p.mediaId] = "blake3:original-with-gps"

        rig.trigger()

        val fresh = rig.store.currentForMedia(1)!!
        assertEquals(OrderState.CONFIRMED, fresh.state)
        assertEquals("blake3:original-with-gps", fresh.contentHash)
        assertFalse(fresh.locationRedacted)
        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.store.get(old.id)!!.state)
        assertEquals(0L, rig.store.countSourceMissingSkipped(0L, Long.MAX_VALUE))
        rig.close()
    }
}
