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

    override fun stopActiveFetch(queueSequence: Long) {
        nativeStopActiveFetch(handle)
    }

    override fun revoke(hash: String) {
        nativeRevoke(handle)
    }

    override fun close() {
        nativeClose(handle)
    }

    companion object {
        init {
            System.loadLibrary("transport")
        }

        @JvmStatic
        external fun nativeOpen(root: String): Long

        @JvmStatic
        external fun nativeRegister(handle: Long, hash: String, fd: Int): String

        @JvmStatic
        external fun nativeStopActiveFetch(handle: Long)

        @JvmStatic
        external fun nativeRevoke(handle: Long)

        @JvmStatic
        external fun nativeClose(handle: Long)

        fun open(filesDir: File): AndroidNativeIrohBlobsProvider {
            val handle = nativeOpen(filesDir.absolutePath)
            check(handle != 0L) { "native iroh-blobs provider did not return a handle" }
            return AndroidNativeIrohBlobsProvider(handle)
        }
    }
}
