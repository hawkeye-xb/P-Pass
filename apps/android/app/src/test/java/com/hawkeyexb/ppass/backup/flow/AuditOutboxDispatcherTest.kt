// AUDIT-01: the phone -> daemon leg of the durable audit outbox (now in the order store, #417).
// Locks in: a successful daemon accept acknowledges exactly the accepted event ids; anything the daemon
// does not report back, or a transport failure, stays in the outbox for the next flush.
// AUDIT-06 (#460): a fact the daemon permanently rejects stays queued but never blocks the facts behind it —
// one flush pages through the whole outbox by seq, however many rejected ones sit in front.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.InMemoryOrderStore
import com.hawkeyexb.ppass.proto.FlowAuditAccepted
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AuditOutboxDispatcherTest {
    private fun pairing() = Pairing(daemonNodeId = "daemon-1", daemonAddrToken = "unused", storageDeviceName = "desk", pairingEpoch = "epoch-1")

    private val store = InMemoryOrderStore { 1L }

    private fun record(id: String) = AuditRecord(id, AuditKinds.ROUND_CONTROLLED, null, 1L, mapOf("action" to "pause"))

    private fun dispatcher(transport: FlowAuditTransport, paired: Boolean = true) = AuditOutboxDispatcher(
        store = store,
        pairing = { if (paired) pairing() else null },
        transportFor = { transport },
        acknowledgeEvents = { ids -> store.acknowledgeAudit(ids) },
    )

    @Test
    fun accepted_event_ids_are_dropped_and_the_rest_stay() {
        store.appendAudit(record("a"))
        store.appendAudit(record("b"))
        val submitted = mutableListOf<List<String>>()
        val transport = object : FlowAuditTransport {
            override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted {
                submitted += events.map { it.eventId }
                return FlowAuditAccepted(eventIds = listOf("a"))
            }
        }
        runBlocking { dispatcher(transport).flush() }
        assertEquals(listOf(listOf("a", "b")), submitted)
        assertEquals(listOf("b"), store.pendingAudit(10).map { it.eventId })
    }

    @Test
    fun transport_failure_leaves_the_outbox_intact() {
        store.appendAudit(record("a"))
        val failing = object : FlowAuditTransport {
            override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted = throw java.io.IOException("offline")
        }
        runBlocking { dispatcher(failing).flush() }
        assertEquals(listOf("a"), store.pendingAudit(10).map { it.eventId })
    }

    @Test
    fun unpaired_or_empty_outbox_never_calls_the_daemon() {
        var calls = 0
        val counting = object : FlowAuditTransport {
            override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted {
                calls++
                return FlowAuditAccepted(eventIds = emptyList())
            }
        }
        runBlocking { dispatcher(counting).flush() }
        store.appendAudit(record("a"))
        runBlocking { dispatcher(counting, paired = false).flush() }
        assertEquals(0, calls)
    }

    /** Like a pre-#460 daemon facing a pre-#460 phone: item facts without itemRef are refused, everything else lands. */
    private fun rejectingItemsWithoutItemRef(submitted: MutableList<List<String>> = mutableListOf()) = object : FlowAuditTransport {
        override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted {
            submitted += events.map { it.eventId }
            return FlowAuditAccepted(eventIds = events.filterNot { it.kind == AuditKinds.ITEM_CONFIRMED && "itemRef" !in it.payload }.map { it.eventId })
        }
    }

    private fun rejected(id: String) = AuditRecord(id, AuditKinds.ITEM_CONFIRMED, null, 1L, mapOf("queueSequence" to id, "contentHash" to "00"))

    // Card acceptance #2 (E2). Reverse proof: flush() reads only the oldest AUDIT_BATCH once (the pre-#460
    // `store.pendingAudit(200)` single shot) -> the legit events behind 250 rejected ones are never sent, red.
    @Test
    fun permanently_rejected_events_in_front_never_block_the_events_behind_them() {
        repeat(250) { store.appendAudit(rejected("stuck-$it")) }
        store.appendAudit(record("decision-1"))
        store.appendAudit(record("decision-2"))
        val submitted = mutableListOf<List<String>>()

        runBlocking { dispatcher(rejectingItemsWithoutItemRef(submitted)).flush() }

        val left = store.pendingAudit(1_000).map { it.eventId }
        assertEquals("the legit events were acknowledged and removed", 250, left.size)
        assertTrue(left.all { it.startsWith("stuck-") })
        assertEquals("rejected ones are kept for a later daemon, not dropped", (0 until 250).map { "stuck-$it" }, left)
        assertEquals("every event is sent exactly once per flush", 252, submitted.flatten().toSet().size)
        assertEquals(252, submitted.flatten().size)
    }

    @Test
    fun a_single_rejected_event_at_the_head_does_not_hold_back_the_rest() {
        store.appendAudit(rejected("stuck"))
        store.appendAudit(record("a"))
        runBlocking { dispatcher(rejectingItemsWithoutItemRef()).flush() }
        assertEquals(listOf("stuck"), store.pendingAudit(10).map { it.eventId })
    }

    // Production acks go through the engine's writer asynchronously (engine.acknowledgeAudit launches a Job), so the
    // next page is read before the previous page's deletes land. The seq cursor must still move forward, never resend.
    @Test
    fun pages_advance_by_seq_even_when_acknowledgements_land_later() {
        repeat(450) { store.appendAudit(record("e-$it")) }
        val deferredAcks = mutableListOf<Set<String>>()
        val submitted = mutableListOf<List<String>>()
        val acceptAll = object : FlowAuditTransport {
            override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted {
                submitted += events.map { it.eventId }
                return FlowAuditAccepted(eventIds = events.map { it.eventId })
            }
        }
        val lateAcking = AuditOutboxDispatcher(
            store = store,
            pairing = { pairing() },
            transportFor = { acceptAll },
            acknowledgeEvents = { ids -> deferredAcks += ids },
        )
        runBlocking { lateAcking.flush() }
        assertEquals(listOf(200, 200, 50), submitted.map { it.size })
        assertEquals(450, submitted.flatten().toSet().size)
        deferredAcks.forEach { store.acknowledgeAudit(it) }
        assertEquals(emptyList<String>(), store.pendingAudit(10).map { it.eventId })
    }

    @Test
    fun a_transport_failure_mid_walk_stops_the_flush_and_keeps_the_rest() {
        repeat(250) { store.appendAudit(record("e-$it")) }
        var calls = 0
        val failsSecond = object : FlowAuditTransport {
            override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted {
                if (++calls == 2) throw java.io.IOException("offline")
                return FlowAuditAccepted(eventIds = events.map { it.eventId })
            }
        }
        runBlocking { dispatcher(failsSecond).flush() }
        assertEquals(2, calls)
        assertEquals((200 until 250).map { "e-$it" }, store.pendingAudit(1_000).map { it.eventId })
    }
}
