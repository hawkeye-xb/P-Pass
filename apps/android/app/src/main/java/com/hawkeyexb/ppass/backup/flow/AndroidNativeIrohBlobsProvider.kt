// REBUILD-01: thin Android binding over transport's JNI iroh-blobs provider.
package com.hawkeyexb.ppass.backup.flow

import android.os.ParcelFileDescriptor
import java.io.File

/**
 * Native provider owner. It imports a duplicated [ParcelFileDescriptor] before
 * returning, so callers keep normal ContentResolver descriptor lifetime rules.
 */
internal class AndroidNativeIrohBlobsProvider private constructor(
    private val handle: Long,
) : NativeIrohBlobsProvider, AutoCloseable {
    override fun register(hash: String, source: Any): String {
        val descriptor = source as? ParcelFileDescriptor
            ?: throw IllegalArgumentException("Android provider source must be a ParcelFileDescriptor")
        return nativeRegister(handle, hash, descriptor.fd)
    }

    override fun importMedia(dataPath: String?, source: Any): String {
        val descriptor = source as? ParcelFileDescriptor
            ?: throw IllegalArgumentException("Android provider source must be a ParcelFileDescriptor")
        return nativeImportMedia(handle, dataPath, descriptor.fd)
    }

    override fun serve(hash: String): String = nativeServe(handle, hash)

    override fun release(hash: String) {
        nativeRelease(handle, hash)
    }

    override fun stopActiveFetch(queueSequence: Long) {
        nativeStopActiveFetch(handle)
    }

    override fun releaseRetention(hash: String) {
        nativeReleaseRetention(handle)
    }

    override fun revoke(hash: String) {
        nativeRevoke(handle)
    }

    override fun transferStatus(): String = nativeTransferStatus(handle)

    override fun networkChange() = nativeNetworkChange(handle)

    /** #434：空闲时关掉 provider 的 endpoint；false = 桌面还连着，稍后再试。 */
    fun park(): Boolean = nativePark(handle)

    /** #434：先把 endpoint 绑上（不等上线），让它和探测桌面并行去连 relay。 */
    fun prewarm() = nativePrewarm(handle)

    override fun setAllowedPeer(daemonNodeId: String?) = nativeSetAllowedPeer(handle, daemonNodeId)

    override fun close() {
        nativeClose(handle)
    }

    companion object {
        init {
            System.loadLibrary("transport")
            // #584：把 Rust/iroh 的 tracing 日志接进 logcat（tag=PPassRust，默认 INFO）。
            // 级别取自系统属性 log.tag.PPassRust：`setprop log.tag.PPassRust DEBUG`
            // 可解锁更低级别，鸿蒙同样支持 log.tag.*。iroh 的 net_report 在 Rust 侧
            // 源头压到 ERROR（#544 同口径，避免打印本机公网地址）。
            runCatching { nativeInitLogging(rustLogLevel()) }
        }

        private fun rustLogLevel(): String =
            runCatching {
                Class.forName("android.os.SystemProperties")
                    .getMethod("get", String::class.java, String::class.java)
                    .invoke(null, "log.tag.PPassRust", "INFO") as String
            }.getOrDefault("INFO")

        @JvmStatic
        external fun nativeOpen(root: String): Long

        /** #584：安装 Rust→logcat 的 tracing subscriber；每进程一次，重复调用保留第一个。 */
        @JvmStatic
        private external fun nativeInitLogging(level: String)

        @JvmStatic
        external fun nativeRegister(handle: Long, hash: String, fd: Int): String

        /** #413：[path] 为 null 时直接从 [fd] 复制。返回导入结果 JSON。 */
        @JvmStatic
        external fun nativeImportMedia(handle: Long, path: String?, fd: Int): String

        /** #413：引用的原图已删 / 已变抛 java.io.FileNotFoundException。 */
        @JvmStatic
        external fun nativeServe(handle: Long, hash: String): String

        @JvmStatic
        external fun nativeRelease(handle: Long, hash: String)

        @JvmStatic
        external fun nativeStopActiveFetch(handle: Long)

        @JvmStatic
        external fun nativeReleaseRetention(handle: Long)

        @JvmStatic
        external fun nativeRevoke(handle: Long)

        @JvmStatic
        external fun nativeTransferStatus(handle: Long): String

        @JvmStatic
        external fun nativeNetworkChange(handle: Long)

        @JvmStatic
        external fun nativePark(handle: Long): Boolean

        @JvmStatic
        external fun nativePrewarm(handle: Long)

        @JvmStatic
        external fun nativeClose(handle: Long)

        /** #547：[nodeId] 为 null / 空 = 谁都不许拉；格式不对抛异常且同样谁都不许。 */
        @JvmStatic
        external fun nativeSetAllowedPeer(handle: Long, nodeId: String?)

        fun open(filesDir: File): AndroidNativeIrohBlobsProvider {
            val handle = nativeOpen(filesDir.absolutePath)
            check(handle != 0L) { "native iroh-blobs provider did not return a handle" }
            return AndroidNativeIrohBlobsProvider(handle)
        }
    }
}
