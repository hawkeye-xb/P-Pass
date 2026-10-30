package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.picked.NewPicked
import com.hawkeyexb.ppass.backup.picked.PickedBatchSummary
import com.hawkeyexb.ppass.backup.picked.PickedItem
import com.hawkeyexb.ppass.backup.picked.PickedState
import com.hawkeyexb.ppass.backup.picked.PickedStore

/** #1272 测试用的内存手选表（语义同 SqlitePickedStore）。 */
internal class InMemoryPickedStore : PickedStore {
    private val rows = mutableListOf<PickedItem>()
    private var nextId = 1L
    private var nextBatch = 1L

    override fun addBatch(items: List<NewPicked>): Long {
        if (items.isEmpty()) return 0L
        val batch = nextBatch++
        for (i in items) rows += PickedItem(nextId++, batch, i.uri, i.fileName, i.mimeType, i.sizeBytes, i.captureAtMs, PickedState.PENDING)
        return batch
    }

    override fun nextOpen(): PickedItem? =
        rows.filter { it.state == PickedState.TRANSFERRING }.minByOrNull { it.id }
            ?: rows.filter { it.state == PickedState.PENDING }.minByOrNull { it.id }

    override fun hasOpen(): Boolean = rows.any { it.state.open }

    override fun mark(id: Long, state: PickedState) {
        val i = rows.indexOfFirst { it.id == id }
        if (i >= 0) rows[i] = rows[i].copy(state = state)
    }

    override fun latestBatch(): PickedBatchSummary? {
        val batch = rows.maxOfOrNull { it.batchId } ?: return null
        val r = rows.filter { it.batchId == batch }
        return PickedBatchSummary(
            batch, r.size, r.count { it.state.open }, r.count { it.state == PickedState.DELIVERED },
            r.count { it.state == PickedState.ALREADY_THERE }, r.count { it.state == PickedState.FAILED },
        )
    }

    override fun clearAll(): List<String> = rows.map { it.uri }.also { rows.clear() }

    override fun clearSettled() {
        rows.removeAll { !it.state.open }
    }
}
