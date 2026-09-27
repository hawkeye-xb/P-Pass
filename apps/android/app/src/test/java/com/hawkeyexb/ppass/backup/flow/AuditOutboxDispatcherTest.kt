// AUDIT-01: the phone -> daemon leg of the durable audit outbox (now in the order store, #417).
// Locks in: a successful daemon accept acknowledges exactly the accepted event ids; anything the daemon
// does not report back, or a transport failure, stays in the outbox for the next flush.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.InMemoryOrderStore
import com.hawkeyexb.ppass.proto.FlowAuditAccepted
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
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
}
