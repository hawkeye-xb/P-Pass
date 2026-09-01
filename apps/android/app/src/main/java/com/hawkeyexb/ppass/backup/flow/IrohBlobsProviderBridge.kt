// REBUILD-01: lease-gated adapter over the Android-native iroh-blobs provider.
package com.hawkeyexb.ppass.backup.flow

/**
 * The native provider imports the source under its declared BLAKE3 hash and
 * serves it through iroh-blobs. Implementations must complete [register]
 * synchronously: the caller may close the source descriptor on return.
 */
internal interface NativeIrohBlobsProvider {
    fun register(hash: String, source: Any): String
    fun stopActiveFetch(queueSequence: Long)
    fun revoke(hash: String)
}

/**
 * Admits exactly the current epoch's leased item to the native provider.
 *
 * The Flow runner owns the epoch and lease; this adapter deliberately has no
 * fallback to an old item, old epoch, raw upload, or application chunk map.
 */
internal class IrohBlobsProviderBridge(
    private val native: NativeIrohBlobsProvider,
    private val openSource: (String) -> Any,
) {
    private var active: ActiveRegistration? = null

    fun register(item: TransferItem, currentEpoch: PairingEpoch, lease: FetchLease): String {
        require(item.pairingEpoch == currentEpoch) { "item is not in the current pairing epoch" }
        require(item.queueSequence == lease.queueSequence) { "item is not the active fetch lease" }
        val hash = requireNotNull(item.contentHash) { "provider requires a confirmed content hash" }
        require(hash.length == HASH_HEX_LENGTH && hash.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) {
            "provider requires a 32-byte lowercase-hex content hash"
        }

        active?.let {
            native.stopActiveFetch(it.queueSequence)
            native.revoke(it.hash)
        }
        val ticket = native.register(hash, openSource(item.sourceRef))
        active = ActiveRegistration(item.queueSequence, lease.leaseToken, hash)
        return ticket
    }

    /**
     * Pause closes the native iroh-blobs connection before revoking the
     * provider. It never deletes a receiver-side partial; a later native fetch
     * sees that partial in its iroh-blobs store and resumes missing ranges.
     */
    fun pause(lease: FetchLease) {
        val current = active ?: return
        require(current.queueSequence == lease.queueSequence) { "lease does not own the active provider" }
        require(current.leaseToken == lease.leaseToken) { "lease token does not own the active provider" }
        native.stopActiveFetch(current.queueSequence)
        native.revoke(current.hash)
        active = null
    }

    private data class ActiveRegistration(
        val queueSequence: Long,
        val leaseToken: String,
        val hash: String,
    )

    private companion object {
        const val HASH_HEX_LENGTH = 64
    }
}
