// REBUILD-01 / ARCH-13 (#417): lease-gated adapter over the Android-native iroh-blobs provider.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.ffi.PeerCloseListener
import java.io.FileNotFoundException

/**
 * NET-14: local ground truth for one lease's transfer, as
 * [NativeIrohBlobsProvider.transferStatus] returns it (mapped from the uniffi record, #1126). This is the receiver-independent fact the phone
 * (as the iroh-blobs *sender* in Flow) can observe about its own connection/event state.
 */
internal sealed interface TransferStatus {
    object NoLease : TransferStatus
    data class Completed(val hash: String) : TransferStatus

    /**
     * [source]（#413）：这次 lease 引用的原图已删 / 已变。iroh 的中止事件不带原因，桌面那边只看到流被重置
     * （报 `fetch_failed`），所以要靠这里区分「源已删」和路径失败。
     */
    data class Aborted(val hash: String, val source: SourceFault? = null) : TransferStatus

    /**
     * [bytesSent] / [byteIdleForMs]（#417，#410 参数）：对端已拉走的文件字节数（`Progress.end_offset`
     * 的最大值）与它上一次前进至今多久。连接类事件不刷新后者。旧版原生库不带这两个字段 → null。
     */
    data class InProgress(
        val connected: Boolean,
        val idleForMs: Long?,
        val bytesSent: Long? = null,
        val byteIdleForMs: Long? = null,
        /** 同 [Aborted.source]：中止事件可能晚于桌面的失败推送，所以进行中也带。 */
        val source: SourceFault? = null,
    ) : TransferStatus
}

/** #413：引用导入的原图在供数期间出了问题。每次查询状态时现场 stat 得出。 */
internal enum class SourceFault { MISSING, CHANGED }

/** #413：原生导入一张原图的结果。[fallback] 非空 = 没能引用、复制了一份（原因见 Rust `ImportFallback`）。 */
internal data class NativeMediaImport(
    val contentHash: String,
    val sizeBytes: Long,
    val byReference: Boolean,
    val fallback: String? = null,
    val detail: String? = null,
)

/**
 * The native provider imports an original (by reference when it can, else by copy), then serves it through
 * iroh-blobs. Implementations must complete [importMedia] synchronously: the caller closes the source
 * descriptor on return.
 */
internal interface NativeIrohBlobsProvider {
    fun stopActiveFetch(queueSequence: Long)
    fun releaseRetention(hash: String)
    fun revoke(hash: String)

    /** NET-14: the current lease's local transfer status (with the #413 source fault merged in). */
    fun transferStatus(): TransferStatus

    /** #417：Android 网络变化回调 → iroh `Endpoint::network_change()`（只作用于 provider 端点）。 */
    fun networkChange() = Unit

    // #413：导入与供数分两步。默认实现只为不破坏只实现旧接口的测试替身。

    /** 引用优先导入 [source]（[dataPath] 可为 null → 复制）。返回后可关闭 [source]。 */
    fun importMedia(dataPath: String?, source: Any): NativeMediaImport = throw UnsupportedOperationException("importMedia")

    /** 让已导入的 [hash] 成为当前 lease 并返回 ticket；引用的原图已删 / 已变抛 [FileNotFoundException]。 */
    fun serve(hash: String): String = throw UnsupportedOperationException("serve")

    /** 放掉 [hash] 的导入（不停在飞的拉取）。幂等。 */
    fun release(hash: String) = Unit

    /**
     * #547：只允许已配对桌面（[daemonNodeId]，64 hex）来拉；null = 谁都不许（解配后）。
     * 原生侧默认就是谁都不许，所以漏调只会让传输失败，不会放行。
     */
    fun setAllowedPeer(daemonNodeId: String?) = Unit

    /**
     * #1126：登记（null = 撤销）provider 入站连接的关闭监听：已配对电脑用应用关闭码关掉连接时回调
     * （电脑 NodeId, code）。与控制面 [DaemonClient] 是同一个监听接口、同一个「配对失效」判据。
     */
    fun setPeerCloseListener(listener: PeerCloseListener?) = Unit
}

/** 一次注册占用 provider 的凭据：queue_sequence = order 行 id，lease_token = [leaseTokenFor]。 */
internal data class ProviderLease(val orderId: Long, val leaseToken: String, val contentHash: String)

/**
 * Admits exactly the current order's lease to the native provider. The loop owns the order and lease;
 * this adapter deliberately has no fallback to an old item, old pairing id, raw upload, or chunk map.
 */
internal class IrohBlobsProviderBridge(
    private val native: NativeIrohBlobsProvider,
) {
    @Volatile
    private var active: ProviderLease? = null

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
        return native.transferStatus()
    }

    fun networkChange() = native.networkChange()

    /** #413：导入一张原图（调用方负责打开与关闭 [source]）。 */
    fun importMedia(dataPath: String?, source: Any): NativeMediaImport = native.importMedia(dataPath, source)

    /**
     * #413：以 [lease] 对外供数它已导入的内容。原图已删 / 已变 → [SourceMissingException]；
     * 没导入过（或已 release）→ 原生侧 IllegalStateException。
     */
    fun serve(lease: ProviderLease): String {
        requireContentHash(lease.contentHash)
        val ticket = try {
            native.serve(lease.contentHash)
        } catch (gone: FileNotFoundException) {
            throw SourceMissingException(gone)
        }
        active = lease
        return ticket
    }

    /** #413：这份内容不再需要。不停当前连接；要停用 [pause]。 */
    fun release(contentHash: String) = native.release(contentHash)

    private fun requireContentHash(hash: String) =
        require(hash.length == HASH_HEX_LENGTH && hash.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) {
            "provider requires a 32-byte lowercase-hex content hash"
        }

    private companion object {
        const val HASH_HEX_LENGTH = 64
    }
}
