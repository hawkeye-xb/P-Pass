package com.hawkeyexb.ppass.backup.picked

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PickedUploadsTest {
    private val source = run {
        var dir: File? = File(System.getProperty("user.dir"))
        val rel = "app/src/main/java/com/hawkeyexb/ppass/backup/picked/PickedUploads.kt"
        var found: File? = null
        while (dir != null && found == null) {
            val direct = File(dir, rel)
            if (direct.isFile) {
                found = direct
                break
            }
            val nested = File(dir, "apps/android/$rel")
            if (nested.isFile) {
                found = nested
                break
            }
            dir = dir.parentFile
        }
        found ?: File(File(System.getProperty("user.dir")), rel)
    }

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
        val uris = uris(1..137)
        val granted = mutableListOf<String>()

        assertEquals(137, enqueue(store, uris, granted))
        assertEquals(137, store.rows.size)
        assertEquals(uris, granted)
        assertEquals(uris, store.rows.map { it.item.uri })
    }

    @Test
    fun `public enqueue forwards the complete uri list to the tested path`() {
        val text = source.readText()
        val entry = text.substringAfter("fun enqueue(context: Context, uris: List<Uri>): Int {")
            .substringBefore("internal fun <T> enqueueValues")

        assertTrue(entry.contains("values = uris"))
        assertFalse("公开入口不得再次截断 URI 列表", Regex("\\btake\\s*\\(").containsMatchIn(entry))
    }

    @Test
    fun `two selections preserve all five in selection order`() {
        val store = FakePickedStore()

        enqueue(store, uris(1..2))
        enqueue(store, uris(3..5))

        assertEquals(listOf(1, 2, 3, 4, 5), store.drain().map { it.item.uri.substringAfterLast('/').toInt() })
        assertEquals(2, store.batches)
    }

    @Test
    fun `empty selection does not create a batch`() {
        val store = FakePickedStore()

        assertEquals(0, enqueue(store, emptyList()))
        assertEquals(0, store.batches)
    }

    private fun uris(range: IntRange): List<String> = range.map { "content://document/$it" }

    private fun enqueue(store: FakePickedStore, values: List<String>, granted: MutableList<String> = mutableListOf()): Int =
        PickedUploads.enqueueValues(
            values = values,
            grant = { granted += it },
            describe = { value -> pick(value.substringAfterLast('/').toInt()) },
            store = store,
        )

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
