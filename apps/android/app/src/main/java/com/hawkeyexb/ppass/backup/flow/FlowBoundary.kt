package com.hawkeyexb.ppass.backup.flow

/**
 * Production-backup boundary established by REBUILD-00.
 *
 * Flow owns the durable per-item facts and their transitions: discovery cursor,
 * strict upload cursor, consumer gate, fetch lease, completion receipt,
 * cancellation round, pairing epoch, and reconciliation facts.
 *
 * The old `backup` package remains a frozen batch implementation. In particular,
 * Flow must not call or import BackupWorker, BackupRunner, ConfirmedStore,
 * ReuploadQueue, WatermarkStore, or the manifest/push/commit protocol. New
 * production behavior belongs in this package and reaches platform transport only
 * through Flow ports/adapters.
 */
internal object FlowBoundary
