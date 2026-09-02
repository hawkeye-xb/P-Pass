// REBUILD-03: phone-side adapter from one leased Flow item to Desktop receipt.
package com.hawkeyexb.ppass.backup.flow

import android.content.ContentResolver
import android.net.Uri
import android.util.Log
import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PeerAddrParts
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import io.github.rctcwyvrn.blake3.Blake3
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject

/** The only Desktop interaction accepted by the Android Flow delivery port. */
internal interface FlowReceiptClient {
    suspend fun currentPairingEpoch(): String?
    suspend fun offer(request: FlowFetchRequest)
    suspend fun fetch(request: FlowFetchRequest): FlowCompletionReceipt
    suspend fun cancel(request: FlowFetchRequest)
}

/** Keeps an in-flight delivery from crossing into a newly paired Desktop epoch. */
internal class FlowDeliveryEpochGuard(private val pairing: () -> Pairing?) {
    fun isCurrent(expectedEpoch: PairingEpoch): Boolean = pairing()?.pairingEpoch == expectedEpoch.value

    fun refreshedEpoch(advertisedEpoch: String?): PairingEpoch? {
        val currentEpoch = pairing()?.pairingEpoch ?: return null
        return advertisedEpoch?.takeIf { it.isNotBlank() && it != currentEpoch }?.let(::PairingEpoch)
    }
}

/** Validates a Desktop receipt then routes it through the owning Flow runner. */
internal fun relayFlowCompletion(
    receipt: FlowCompletionReceipt,
    request: FlowFetchRequest,
    onReceipt: (CompletionReceipt) -> Unit,
) {
    require(receipt.queueSequence == request.queueSequence)
    require(receipt.pairingEpoch == request.pairingEpoch)
    require(receipt.leaseToken == request.leaseToken)
    require(receipt.contentHash == request.contentHash)
    onReceipt(
        CompletionReceipt(
            queueSequence = receipt.queueSequence,
            receiptId = receipt.receiptId,
            pairingEpoch = PairingEpoch(receipt.pairingEpoch),
            leaseToken = receipt.leaseToken,
            contentHash = receipt.contentHash,
        ),
    )
}

/** Ctrl-plane adapter; data stays on native iroh-blobs through the ticket. */
internal class DaemonFlowReceiptClient(
    private val client: DaemonClient,
    private val peer: PeerAddrParts,
) : FlowReceiptClient {
    override suspend fun currentPairingEpoch(): String? {
        val response = client.call(peer, Methods.HELLO, buildJsonObject {})
        check(response.ok) { "hello: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(Hello.serializer(), checkNotNull(response.result)).pairingEpoch
    }

    override suspend fun offer(request: FlowFetchRequest) {
        val response = client.call(peer, Methods.FLOW_OFFER, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        check(response.ok) { "flow.offer: ${response.error?.msgKey}" }
    }

    override suspend fun fetch(request: FlowFetchRequest): FlowCompletionReceipt {
        val response = client.call(peer, Methods.FLOW_FETCH, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        check(response.ok) { "flow.fetch: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(FlowCompletionReceipt.serializer(), checkNotNull(response.result))
    }

    override suspend fun cancel(request: FlowFetchRequest) {
        val response = client.call(peer, Methods.FLOW_CANCEL, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        check(response.ok) { "flow.cancel: ${response.error?.msgKey}" }
    }
}

/**
 * Registers precisely the strict head with Android's native provider, then asks
 * Desktop to offer and fetch that exact ticket. Receipt fields are checked again
 * before they are allowed to mutate the ledger.
 */
internal class NativeFlowDeliveryPort(
    private val ledger: DiscoveryLedgerStore,
    private val bridge: IrohBlobsProviderBridge,
    private val resolver: ContentResolver,
    private val pairing: () -> Pairing?,
    private val identityKey: () -> ByteArray,
    private val onPermanentFailure: () -> Unit,
    private val onReceipt: (CompletionReceipt) -> Unit,
    private val onPairingEpochRefreshed: (PairingEpoch) -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : DeliveryPort {
    private var active: ActiveDelivery? = null
    private val epochGuard = FlowDeliveryEpochGuard(pairing)

    override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
        val currentPairing = requireNotNull(pairing()) { "Flow delivery requires an active pairing" }
        val epoch = PairingEpoch(currentPairing.pairingEpoch)
        require(epoch == item.pairingEpoch) { "item is not in the current pairing epoch" }
        val hashed = item.copy(contentHash = item.contentHash ?: hashSource(item.sourceRef))
        ledger.update { snapshot ->
            snapshot.copy(items = snapshot.items.map { candidate ->
                if (candidate.queueSequence == item.queueSequence) hashed else candidate
            })
        }
        val ticket = bridge.register(hashed, epoch, lease)
        val request = FlowFetchRequest(
            queueSequence = hashed.queueSequence,
            pairingEpoch = epoch.value,
            leaseToken = lease.leaseToken,
            contentHash = requireNotNull(hashed.contentHash),
            fileName = hashed.fileName.ifBlank { hashed.sourceRef.substringAfterLast('/') },
            mediaType = hashed.mediaType,
            provider = ticket,
        )
        active = ActiveDelivery(lease, request)
        scope.launch {
            try {
                require(epochGuard.isCurrent(epoch)) { "Flow delivery pairing epoch changed before offer" }
                val desktop = DaemonFlowReceiptClient(
                    DaemonClient().also { it.bind(identityKey()) },
                    parsePeerAddrToken(currentPairing.daemonAddrToken),
                )
                epochGuard.refreshedEpoch(desktop.currentPairingEpoch())?.let { refreshedEpoch ->
                    bridge.pause(lease)
                    active = null
                    onPairingEpochRefreshed(refreshedEpoch)
                    return@launch
                }
                desktop.offer(request)
                require(epochGuard.isCurrent(epoch)) { "Flow delivery pairing epoch changed before fetch" }
                val receipt = desktop.fetch(request)
                require(epochGuard.isCurrent(epoch)) { "Flow delivery pairing epoch changed before receipt" }
                acceptReceipt(receipt, request)
            } catch (failure: Throwable) {
                if (!epochGuard.isCurrent(epoch)) {
                    Log.i("PPassFlow", "Discarding stale Flow delivery after pairing epoch changed")
                    bridge.pause(lease)
                    active = null
                    return@launch
                }
                Log.e("PPassFlow", "Native Flow delivery failed; preserving the strict head for retry", failure)
                onPermanentFailure()
            }
        }
    }

    override fun stop(queueSequence: Long): PartialDisposition {
        val current = active?.takeIf { it.lease.queueSequence == queueSequence } ?: return PartialDisposition.RETAINED
        bridge.pause(current.lease)
        scope.launch {
            runCatching {
                val currentPairing = pairing() ?: return@runCatching
                val desktop = DaemonFlowReceiptClient(
                    DaemonClient().also { it.bind(identityKey()) },
                    parsePeerAddrToken(currentPairing.daemonAddrToken),
                )
                desktop.cancel(current.request)
            }
        }
        active = null
        return PartialDisposition.RETAINED
    }

    private fun acceptReceipt(receipt: FlowCompletionReceipt, request: FlowFetchRequest) {
        relayFlowCompletion(receipt, request, onReceipt)
    }

    private fun hashSource(sourceRef: String): String {
        val hasher = Blake3.newInstance()
        resolver.openInputStream(Uri.parse(sourceRef)).use { input ->
            requireNotNull(input) { "cannot open Flow source" }
            val buffer = ByteArray(256 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hasher.update(if (count == buffer.size) buffer else buffer.copyOf(count))
            }
        }
        return hasher.hexdigest()
    }

    private data class ActiveDelivery(val lease: FetchLease, val request: FlowFetchRequest)
}
