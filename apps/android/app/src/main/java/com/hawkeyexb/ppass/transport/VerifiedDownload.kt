// MOB-115: 下载平面（ppf/download/1）的字节接收——只交付完整且内容正确的文件。
//
// 旧实现读失败就 `break`，之后不查 received == total，断流时把截断文件当
// 完整文件返回，视频页又把它长期缓存。这里的约定：
//  ① 字节先写同目录的 `<dest>.part`，结束后校验长度、再校验 BLAKE3
//     （asset hash 本身就是全文件 BLAKE3，daemon 收上传时也按它校验，见
//     crates/daemon/src/upload.rs），全部通过才原子改名为 dest；
//  ② 任何失败都抛明确的异常，并删掉 `.part`——失败路径上绝不出现 dest；
//  ③ 取消（CancellationException）原样抛出，不包装。
// 读点只有 [readChunk] 一处：NET-09（#116）的停滞判据只需包住它，不必动循环。
package com.hawkeyexb.ppass.transport

import io.github.rctcwyvrn.blake3.Blake3
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.coroutines.cancellation.CancellationException

/** 下载失败的共同父类——调用方只需 catch 这一类即可区分「下载坏了」。 */
sealed class AssetDownloadException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

/** 对端没给出总长度（协议要求 Resp.result.bytes 必有）。 */
class DownloadLengthUnknown(hash: String) :
    AssetDownloadException("download $hash: daemon did not declare byte length")

/** 断流 / 提前结束：收到的字节少于对端声明的总长度。 */
class DownloadTruncated(val received: Long, val total: Long, cause: Throwable? = null) :
    AssetDownloadException("download truncated: $received of $total bytes", cause)

/** 长度对上了但内容的 BLAKE3 与请求的 hash 不符。 */
class DownloadHashMismatch(val expected: String, val actual: String) :
    AssetDownloadException("download hash mismatch: expected $expected, got $actual")

private const val CHUNK: Long = 256L * 1024

/** [dest] 对应的临时文件（同目录，保证改名原子）。 */
internal fun partFileFor(dest: File): File = File(dest.absoluteFile.parentFile, dest.name + ".part")

/**
 * 从 [readChunk] 读满 [total] 字节写到 [dest]，校验长度与 BLAKE3 后原子落盘。
 * [readChunk] 语义同 iroh `RecvStream.readExact`：要么返回恰好 n 字节，要么抛错。
 * 返回写入的字节数（= total）。
 */
internal suspend fun receiveVerified(
    dest: File,
    total: Long,
    expectedHash: String,
    readChunk: suspend (UInt) -> ByteArray,
    onProgress: (Long, Long) -> Unit = { _, _ -> },
): Long {
    val part = partFileFor(dest)
    var committed = false
    try {
        part.delete()
        val hasher = Blake3.newInstance()
        var received = 0L
        part.outputStream().use { out ->
            while (received < total) {
                val want = minOf(CHUNK, total - received)
                val chunk = try {
                    readChunk(want.toUInt())
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    throw DownloadTruncated(received, total, e)
                }
                if (chunk.isEmpty()) throw DownloadTruncated(received, total)
                out.write(chunk)
                hasher.update(chunk)
                received += chunk.size
                onProgress(received, total)
            }
        }
        if (received != total) throw DownloadTruncated(received, total)
        val actual = hasher.hexdigest()
        if (!actual.equals(expectedHash, ignoreCase = true)) {
            throw DownloadHashMismatch(expectedHash, actual)
        }
        Files.move(
            part.toPath(), dest.toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
        )
        committed = true
        return received
    } finally {
        if (!committed) part.delete()
    }
}
