// UI-10 item 2: the reupload notice card's data source. The LEGACY
// ReuploadQueue is frozen (REBUILD-00) and BackupUiStateHolder never wrote
// its own count — `reuploadNoticeCount > 0` was permanently false, so the
// notice never showed even when a remote-missing recovery was really
// pending (source-read finding, 2026-09-06). This locks the ledger-derived
// replacement to the durable NEEDS_DECISION fact instead.
package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class UI10ReuploadNoticeTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-ui10-notice-$case").toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    @Test
    fun counts_only_needs_decision_items() {
        val dir = tempDir("mixed")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(
            listOf(candidate(1), candidate(2), candidate(3)),
            DiscoveryCursor(1L, 3L),
        )
        ledger.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.mapIndexed { index, item ->
                    when (index) {
                        // Item 1: confirmed, remote lost, source still on
                        // the phone — this is the "bringing it back" case.
                        0 -> item.copy(
                            deliveryState = DeliveryState.CONFIRMED,
                            disposition = RecoveryDisposition.NEEDS_DECISION,
                        )
                        // Item 2: confirmed and remote/source both fine —
                        // must NOT count.
                        1 -> item.copy(
                            deliveryState = DeliveryState.CONFIRMED,
                            disposition = RecoveryDisposition.NONE,
                        )
                        // Item 3: confirmed but unrecoverable (source also
                        // gone) — a different UX concern, not "重传".
                        else -> item.copy(
                            deliveryState = DeliveryState.CONFIRMED,
                            disposition = RecoveryDisposition.UNRECOVERABLE,
                        )
                    }
                },
            )
        }

        assertEquals(1, flowReuploadNoticeCount(ledger.load()))
        dir.deleteRecursively()
    }

    @Test
    fun empty_ledger_counts_zero() {
        assertEquals(0, flowReuploadNoticeCount(DiscoveryLedgerSnapshot()))
    }
}
