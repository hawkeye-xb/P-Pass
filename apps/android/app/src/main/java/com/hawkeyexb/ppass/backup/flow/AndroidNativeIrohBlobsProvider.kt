// #1126: thin Android binding over the shared uniffi `Provider` (crates/transport/src/mobile_ffi.rs,
// the same iroh-blobs provider iOS uses). The hand-written JNI of REBUILD-01 is gone.
package com.hawkeyexb.ppass.backup.flow

import android.os.ParcelFileDescriptor
import com.hawkeyexb.ppass.ffi.FfiException
import com.hawkeyexb.ppass.ffi.MediaImport
import com.hawkeyexb.ppass.ffi.PeerCloseListener
import com.hawkeyexb.ppass.ffi.Provider
import com.hawkeyexb.ppass.ffi.initLogcatLogging
import java.io.File
import java.io.FileNotFoundException
import com.hawkeyexb.ppass.ffi.TransferStatus as FfiTransferStatus

/**
 * Native provider owner. It imports a duplicated [ParcelFileDescriptor] before
 * returning, so callers keep normal ContentResolver descriptor lifetime rules.
 *
 * 进程内单例约束不变（MOB-91 / MOB-62）：同一进程第二次打开会永久阻塞，见 `AndroidFlowRuntime.sharedNativeProvider`。
 */
internal class AndroidNativeIrohBlobsProvider private constructor(
    private val provider: Provider,
) : NativeIrohBlobsProvider, AutoCloseable {
    override fun importMedia(dataPath: String?, source: Any): NativeMediaImport {
        val descriptor = source as? ParcelFileDescriptor
            ?: throw IllegalArgumentException("Android provider source must be a ParcelFileDescriptor")
        return ffi { provider.importMedia(dataPath, descriptor.fd) }.toNative()
    }

    /** #413：引用的原图已删 / 已变 → [FileNotFoundException]（桥把它译成 [SourceMissingException]）；其余 [IllegalStateException]。 */
    override fun serve(hash: String): String = ffi { provider.serve(hash) }

    override fun release(hash: String) {
        ffi { provider.release(hash) }
    }

    override fun stopActiveFetch(queueSequence: Long) {
        provider.stopActiveFetch()
    }

    override fun releaseRetention(hash: String) {
        provider.releaseRetention()
    }

    override fun revoke(hash: String) {
        provider.revoke()
    }

    /** 状态与原图故障分两次调用取；合并规则（`Completed` 不附带故障）见 [mergeTransferStatus]。 */
    override fun transferStatus(): TransferStatus = mergeTransferStatus(provider.transferStatus(), provider.sourceFault())

    override fun networkChange() = provider.networkChange()

    /** #434：空闲时关掉 provider 的 endpoint；false = 桌面还连着，稍后再试。 */
    fun park(): Boolean = provider.park()

    /** #434：先把 endpoint 绑上（不等上线），让它和探测桌面并行去连 relay。 */
    fun prewarm() {
        ffi { provider.prewarm() }
    }

    /** #547：[daemonNodeId] 为 null / 空 = 谁都不许拉；格式不对抛异常且同样谁都不许。 */
    override fun setAllowedPeer(daemonNodeId: String?) {
        ffi { provider.setAllowedPeer(daemonNodeId) }
    }

    override fun setPeerCloseListener(listener: PeerCloseListener?) = provider.setPeerCloseListener(listener)

    /** 等同原 JNI 的 close：先 revoke（停在飞的传输、放掉 temp tag），再放掉 Rust 对象。 */
    override fun close() {
        provider.shutdown()
        provider.close()
    }

    companion object {
        init {
            // #584：把 Rust/iroh 的 tracing 日志接进 logcat（tag=PPassRust，默认 INFO）。
            // 级别取自系统属性 log.tag.PPassRust：`setprop log.tag.PPassRust DEBUG`
            // 可解锁更低级别，鸿蒙同样支持 log.tag.*。iroh 的 net_report 在 Rust 侧
            // 源头压到 ERROR（#544 同口径，避免打印本机公网地址）。每进程一次，重复调用保留第一个。
            runCatching { initLogcatLogging(rustLogLevel()) }
        }

        private fun rustLogLevel(): String =
            runCatching {
                Class.forName("android.os.SystemProperties")
                    .getMethod("get", String::class.java, String::class.java)
                    .invoke(null, "log.tag.PPassRust", "INFO") as String
            }.getOrDefault("INFO")

        /**
         * 打开并**在返回前**登记 [peerClose]（#1126）：已配对电脑用应用关闭码关掉 provider 入站连接时回调，
         * 与控制面同一个监听接口 / 判据，不另写。
         */
        fun open(filesDir: File, peerClose: PeerCloseListener): AndroidNativeIrohBlobsProvider {
            val provider = ffi { Provider(filesDir.absolutePath) }
            provider.setPeerCloseListener(peerClose)
            return AndroidNativeIrohBlobsProvider(provider)
        }
    }
}

/** 原生异常经 [providerFailure] 译成 JVM 异常；原始 [FfiException] 留作 cause。 */
private inline fun <T> ffi(block: () -> T): T =
    try {
        block()
    } catch (error: FfiException) {
        throw providerFailure(error)
    }

/**
 * 原 JNI 的异常口径：引用的原图已删 / 已变（`SourceFault`）→ [FileNotFoundException]（#413 的 source-missing 信号，
 * 桥把它译成 [SourceMissingException]）；其余一律 [IllegalStateException]。
 */
internal fun providerFailure(error: FfiException): Exception =
    if (error is FfiException.SourceFault) {
        FileNotFoundException(error.message).apply { initCause(error) }
    } else {
        IllegalStateException(error.message, error)
    }

/** uniffi 记录 → 领域类型。校验 hash 形状（原 JSON 解析路径的同一条检查）。 */
internal fun MediaImport.toNative(): NativeMediaImport {
    require(hash.length == 64) { "native import returned a malformed hash" }
    return NativeMediaImport(hash, size.toLong(), byReference, fallback, detail)
}

/**
 * uniffi 状态 + 原图故障 → 领域状态。原 `status_wire` 的规则：`Completed` 已拿到全部字节，不附带故障；
 * `Aborted` / `InProgress` 附带 `"missing"` / `"changed"`，其它字串当没有。
 */
internal fun mergeTransferStatus(status: FfiTransferStatus, fault: String?): TransferStatus {
    val source = when (fault) {
        "missing" -> SourceFault.MISSING
        "changed" -> SourceFault.CHANGED
        else -> null
    }
    return when (status) {
        is FfiTransferStatus.NoLease -> TransferStatus.NoLease
        is FfiTransferStatus.Completed -> TransferStatus.Completed(status.hash)
        is FfiTransferStatus.Aborted -> TransferStatus.Aborted(status.hash, source)
        is FfiTransferStatus.InProgress -> TransferStatus.InProgress(
            connected = status.connected,
            idleForMs = status.idleForMs?.toLong(),
            bytesSent = status.bytesSent?.toLong(),
            byteIdleForMs = status.byteIdleForMs?.toLong(),
            source = source,
        )
    }
}
