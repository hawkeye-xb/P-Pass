package com.hawkeyexb.ppass.backup.picked

import org.junit.Assert.assertEquals
import org.junit.Test

class PickedUploadsTest {
    private fun pick(n: Int) = NewPicked(
        uri = "content://document/$n",
        fileName = "$n.mp4",
        mimeType = "video/mp4",
        sizeBytes = n.toLong(),
        captureAtMs = 0L,
    )

    @Test
    fun `file selection over one hundred is fully enqueued`() {
        val store = FakePickedStore()
        val items = (1..137).map(::pick)

        assertEquals(137, PickedUploads.enqueueDescribed(store, items))
        assertEquals(137, store.rows.size)
        assertEquals(items.map { it.uri }, store.rows.map { it.item.uri })
    }

    @Test
    fun `two selections preserve all five in selection order`() {
        val store = FakePickedStore()

        PickedUploads.enqueueDescribed(store, listOf(pick(1), pick(2)))
        PickedUploads.enqueueDescribed(store, listOf(pick(3), pick(4), pick(5)))

        assertEquals(listOf(1, 2, 3, 4, 5), store.drain().map { it.item.uri.substringAfterLast('/').toInt() })
        assertEquals(2, store.batches)
    }

    @Test
    fun `empty selection does not create a batch`() {
        val store = FakePickedStore()

        assertEquals(0, PickedUploads.enqueueDescribed(store, emptyList()))
        assertEquals(0, store.batches)
    }

    private class FakePickedStore : PickedStore {
        data class Row(val id: Long, val batchId: Long, val item: NewPicked, var state: PickedState = PickedState.PENDING)

        val rows = mutableListOf<Row>()
        var batches = 0L
        private var nextId = 1L

        override fun addBatch(items: List<NewPicked>): Long {
            if (items.isEmpty()) return 0L
            batches += 1
            items.forEach { rows += Row(nextId++, batches, it) }
            return batches
        }

        override fun nextOpen(): PickedItem? = rows.firstOrNull { it.state == PickedState.TRANSFERRING }
            .let { transferring ->
                transferring ?: rows.firstOrNull { it.state == PickedState.PENDING }
            }?.toPickedItem()

        override fun hasOpen(): Boolean = rows.any { it.state.open }

        override fun mark(id: Long, state: PickedState) {
            rows.first { it.id == id }.state = state
        }

        override fun latestBatch(): PickedBatchSummary? = null

        override fun clearSettled() {
            rows.removeAll { !it.state.open }
        }

        override fun clearAll(): List<String> = rows.map { it.item.uri }.also { rows.clear() }

        fun drain(): List<Row> {
            val out = mutableListOf<Row>()
            while (true) {
                val next = nextOpen() ?: break
                out += rows.first { it.id == next.id }
                mark(next.id, PickedState.DELIVERED)
            }
            return out
        }

        private fun Row.toPickedItem() = PickedItem(
            id = id,
            batchId = batchId,
            uri = item.uri,
            fileName = item.fileName,
            mimeType = item.mimeType,
            sizeBytes = item.sizeBytes,
            captureAtMs = item.captureAtMs,
            state = state,
        )
    }
}
