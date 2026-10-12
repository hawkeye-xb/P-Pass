// #851：「用原图替换旧副本」待办的 SQL 口径（与 OrderStoreContract 里同名用例逐字对应）。
package com.hawkeyexb.ppass.backup.order

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LOC851RedactionBacklogDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val store = SqliteOrderStore.open(context, name = null)

    @After
    fun close() = store.close()

    private fun newOrder(mediaId: Long, state: OrderState, hash: String = "h$mediaId", redacted: Boolean = true) =
        NewOrder(mediaId, "v1", 7, hash, state, "e3", locationRedacted = redacted)

    @Test
    fun backlogListsOnlyCurrentConfirmedRedactedRowsWithoutAVerdict() {
        val redacted = store.insert(newOrder(1, OrderState.CONFIRMED))
        store.insert(newOrder(2, OrderState.CONFIRMED, redacted = false))
        store.insert(newOrder(3, OrderState.FAILED))
        store.insert(newOrder(4, OrderState.CONFIRMED))
        store.insert(newOrder(4, OrderState.CONFIRMED, hash = "original4", redacted = false))
        val gone = store.insert(newOrder(5, OrderState.CONFIRMED))
        store.setSourceMissing(gone.id, true)
        val refused = store.insert(newOrder(6, OrderState.CONFIRMED))
        val same = store.insert(newOrder(7, OrderState.CONFIRMED))

        assertEquals(listOf(redacted.id, refused.id, same.id), store.locationRedactedAfter(0L, 10).map { it.id })
        assertEquals(listOf(refused.id), store.locationRedactedAfter(redacted.id, 1).map { it.id })

        store.resolveLocationRedaction(refused.id, refused = true)
        store.resolveLocationRedaction(same.id, refused = false)
        assertEquals(listOf(redacted.id), store.locationRedactedAfter(0L, 10).map { it.id })
        assertTrue(store.get(refused.id)!!.locationRedacted)
        assertFalse(store.get(same.id)!!.locationRedacted)
    }
}
