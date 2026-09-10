// AUDIT-01: the phone -> daemon leg of the durable Flow audit outbox.
// Locks in: a successful daemon accept acknowledges (drops) exactly the
// accepted event ids from the ledger outbox; anything the daemon does
// not report back, or a transport failure, must leave the outbox intact
// for the next trigger to retry — never silently dropped on send.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowAuditAccepted
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.Pairing
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AuditOutboxDispatcherTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-audit01-dispatcher-$case").toFile()

    private fun pairing() = Pairing(
        daemonNodeId = "daemon-1",
        // Never actually parsed in these tests: transportFor is fully
        // replaced by a fake, so this token's shape is irrelevant.
        daemonAddrToken = "unused",
        storageDeviceName = "客厅的电脑",
        pairingEpoch = "epoch-1",
    )

    private class RecordingTransport(
        private val accept: (List<AuditOutboxEvent>) -> FlowAuditAccepted,
    ) : FlowAuditTransport {
        val submitted = mutableListOf<List<AuditOutboxEvent>>()
        override suspend fun submit(events: List<AuditOutboxEvent>): FlowAuditAccepted {
            submitted += events
            return accept(events)
        }
    }

    private class FailingTransport(private val failure: Throwable) : FlowAuditTransport {
        override suspend fun submit(events: List<AuditOutboxEvent>): FlowAuditAccepted = throw failure
    }

    @Test
    fun accepted_event_ids_are_dropped_from_the_outbox() {
        val dir = tempDir("accepted")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.update { it.appendAudit(AuditKinds.ROUND_CONTROLLED, payload = mapOf("action" to "pause")) }
        val eventId = ledger.load().auditOutbox.single().eventId

        val transport = RecordingTransport { events -> FlowAuditAccepted(eventIds = events.map { it.eventId }) }
        val dispatcher = AuditOutboxDispatcher(
            ledger = ledger,
            pairing = { pairing() },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            transportFor = { transport },
        )

        runBlocking { dispatcher.flush() }

        assertEquals(1, transport.submitted.size)
        assertEquals(eventId, transport.submitted.single().single().eventId)
        assertTrue("an accepted event must be dropped from the outbox", ledger.load().auditOutbox.isEmpty())
        dir.deleteRecursively()
    }

    @Test
    fun an_event_the_daemon_did_not_report_back_stays_queued_for_retry() {
        val dir = tempDir("partial-accept")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.update { it.appendAudit(AuditKinds.SCOPE_CHANGED, payload = mapOf("scopeRevision" to "2")) }
        ledger.update { it.appendAudit(AuditKinds.EPOCH_INVALIDATED, payload = mapOf("previousEpoch" to "e1")) }
        val ids = ledger.load().auditOutbox.map { it.eventId }

        // Daemon only reports the first id back — e.g. the second write
        // failed on the daemon side. It must stay in the outbox.
        val transport = RecordingTransport { _ -> FlowAuditAccepted(eventIds = listOf(ids[0])) }
        val dispatcher = AuditOutboxDispatcher(
            ledger = ledger,
            pairing = { pairing() },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            transportFor = { transport },
        )

        runBlocking { dispatcher.flush() }

        val remaining = ledger.load().auditOutbox
        assertEquals(1, remaining.size)
        assertEquals(ids[1], remaining.single().eventId)
        dir.deleteRecursively()
    }

    @Test
    fun a_transport_failure_leaves_the_whole_outbox_untouched() {
        val dir = tempDir("transport-failure")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.update { it.appendAudit(AuditKinds.ITEM_ATTENTION, payload = mapOf("reason" to "delivery_failed")) }
        val before = ledger.load().auditOutbox

        val dispatcher = AuditOutboxDispatcher(
            ledger = ledger,
            pairing = { pairing() },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            transportFor = { FailingTransport(RuntimeException("network blip")) },
        )

        runBlocking { dispatcher.flush() }

        assertEquals("a failed flush must not lose or duplicate outbox entries", before, ledger.load().auditOutbox)
        dir.deleteRecursively()
    }

    @Test
    fun an_empty_outbox_never_contacts_the_transport() {
        val dir = tempDir("empty-outbox")
        val ledger = DiscoveryLedgerStore(dir)
        var contacted = false
        val dispatcher = AuditOutboxDispatcher(
            ledger = ledger,
            pairing = { pairing() },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            transportFor = {
                contacted = true
                RecordingTransport { events -> FlowAuditAccepted(eventIds = events.map { it.eventId }) }
            },
        )

        runBlocking { dispatcher.flush() }

        assertTrue("an empty outbox must not open a connection", !contacted)
        dir.deleteRecursively()
    }

    @Test
    fun an_unpaired_phone_never_contacts_the_transport() {
        val dir = tempDir("unpaired")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.update { it.appendAudit(AuditKinds.ROUND_CONTROLLED, payload = mapOf("action" to "cancel")) }
        var contacted = false
        val dispatcher = AuditOutboxDispatcher(
            ledger = ledger,
            pairing = { null },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            transportFor = {
                contacted = true
                RecordingTransport { events -> FlowAuditAccepted(eventIds = events.map { it.eventId }) }
            },
        )

        runBlocking { dispatcher.flush() }

        assertTrue("an unpaired phone must not attempt delivery", !contacted)
        assertEquals(1, ledger.load().auditOutbox.size)
        dir.deleteRecursively()
    }
}
