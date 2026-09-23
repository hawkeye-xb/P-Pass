// REBUILD-01 / ARCH-13 (#417): lease-gated adapter over the Android-native iroh-blobs provider.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.ProtoJson
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * NET-14: local ground truth for one lease's transfer, decoded from the JSON
 * [NativeIrohBlobsProvider.transferStatus] returns. This is the receiver-independent fact the phone
 * (as the iroh-blobs *sender* in Flow) can observe about its own connection/event state.
 */
internal sealed interface TransferStatus {
    object NoLease : TransferStatus
    data class Completed(val hash: String) : TransferStatus
    data class Aborted(val hash: String) : TransferStatus

    /**
     * [bytesSent] / [byteIdleForMs]（#417，#410 参数）：对端已拉走的文件字节数（`Progress.end_offset`
     * 的最大值）与它上一次前进至今多久。连接类事件不刷新后者。旧版原生库不带这两个字段 → null。
     */
    data class InProgress(
        val connected: Boolean,
        val idleForMs: Long?,
        val bytesSent: Long? = null,
        val byteIdleForMs: Long? = null,
    ) : TransferStatus
}

@Serializable
private data class WireTransferStatus(
    val state: String = "",
    val hash: String? = null,
    val connected: Boolean? = null,
    @SerialName("idle_for_ms") val idleForMs: Long? = null,
    @SerialName("bytes_sent") val bytesSent: Long? = null,
    @SerialName("byte_idle_for_ms") val byteIdleForMs: Long? = null,
)

/**
 * Pure decode — JVM-testable without touching the native library. An unrecognized `state` degrades to
 * [TransferStatus.NoLease] rather than throwing: this is a local convenience signal, not a durable contract.
 */
internal fun parseTransferStatus(json: String): TransferStatus {
    val wire = ProtoJson.decodeFromString(WireTransferStatus.serializer(), json)
    return when (wire.state) {
        "completed" -> wire.hash?.let(TransferStatus::Completed) ?: TransferStatus.NoLease
        "aborted" -> wire.hash?.let(TransferStatus::Aborted) ?: TransferStatus.NoLease
        "in_progress" -> TransferStatus.InProgress(wire.connected ?: false, wire.idleForMs, wire.bytesSent, wire.byteIdleForMs)
        else -> TransferStatus.NoLease
    }
}

/**
 * The native provider imports the source under its declared BLAKE3 hash and serves it through
 * iroh-blobs. Implementations must complete [register] synchronously: the caller may close the source
 * descriptor on return.
 */
internal interface NativeIrohBlobsProvider {
    fun register(hash: String, source: Any): String
    fun stopActiveFetch(queueSequence: Long)
    fun releaseRetention(hash: String)
    fun revoke(hash: String)

    /** NET-14: raw JSON of the current lease's local transfer status (see [parseTransferStatus]). */
    fun transferStatus(): String

    /** #417：Android 网络变化回调 → iroh `Endpoint::network_change()`（只作用于 provider 端点）。 */
    fun networkChange() = Unit
}

/** 一次注册占用 provider 的凭据：queue_sequence = order 行 id，lease_token = [leaseTokenFor]。 */
internal data class ProviderLease(val orderId: Long, val leaseToken: String, val contentHash: String)

/**
 * Admits exactly the current order's lease to the native provider. The loop owns the order and lease;
 * this adapter deliberately has no fallback to an old item, old epoch, raw upload, or chunk map.
 */
internal class IrohBlobsProviderBridge(
    private val native: NativeIrohBlobsProvider,
    private val openSource: (String) -> Any,
) {
    @Volatile
    private var active: ProviderLease? = null

    fun register(lease: ProviderLease, sourceUri: String): String {
        val hash = lease.contentHash
        require(hash.length == HASH_HEX_LENGTH && hash.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) {
            "provider requires a 32-byte lowercase-hex content hash"
        }
        // Keep the native endpoint and its ALPN handler alive: stopping it between ordinary items would
        // close the daemon's cached `(NodeId, ALPN)` connection and force a new handshake per file.
        val source = openSource(sourceUri)
        val ticket = try {
            native.register(hash, source)
        } finally {
            (source as? AutoCloseable)?.close()
        }
        active = lease
        return ticket
    }

    /**
     * Pause closes the native iroh-blobs connection before revoking the provider. It never deletes a
     * receiver-side partial; a later native fetch resumes missing ranges.
     */
    fun pause(lease: ProviderLease) {
        val current = active ?: return
        if (current.orderId != lease.orderId || current.leaseToken != lease.leaseToken) return
        native.stopActiveFetch(current.orderId)
        native.revoke(current.contentHash)
        active = null
    }

    /** BLOB-03: release provider retention after a validated receipt; the endpoint stays for reuse. */
    fun releaseRetention(lease: ProviderLease) {
        val current = active ?: return
        require(current.orderId == lease.orderId) { "lease does not own the active provider" }
        require(current.leaseToken == lease.leaseToken) { "lease token does not own the active provider" }
        native.releaseRetention(current.contentHash)
    }

    /** NET-14: local ground truth for the current lease's transfer, or [TransferStatus.NoLease]. */
    fun transferStatus(): TransferStatus {
        if (active == null) return TransferStatus.NoLease
        return parseTransferStatus(native.transferStatus())
    }

    fun networkChange() = native.networkChange()

    private companion object {
        const val HASH_HEX_LENGTH = 64
    }
}
