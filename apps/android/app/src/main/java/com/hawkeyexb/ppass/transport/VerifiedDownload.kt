// MOB-115: 下载平面（ppf/download/1）的字节接收——只交付完整且内容正确的文件。
//
// 旧实现读失败就 `break`，之后不查 received == total，断流时把截断文件当
// 完整文件返回，视频页又把它长期缓存。这里的约定：
//  ① 字节先写同目录的 `<dest>.part`，结束后校验长度、再校验 BLAKE3
//     （asset hash 本身就是全文件 BLAKE3，daemon 收上传时也按它校验，见
//     crates/daemon/src/upload.rs），全部通过才原子改名为 dest；
//  ② 任何失败都抛明确的异常，并删掉 `.part`——失败路径上绝不出现 dest；
//  ③ 取消（CancellationException）原样抛出，不包装。
// 读点只有 [readChunk] 一处：NET-09（#116）的字节停滞看门狗（[ByteStallGuard]）
// 就包在这一处，循环本身不动。
package com.hawkeyexb.ppass.transport

import io.github.rctcwyvrn.blake3.Blake3
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull

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

/**
 * NET-09（#116）：连续这么久一个新字节都没收到 = 对端不再流动，判这次下载失败。
 * 盯的是「零进展」不是总时长——每收到一块就重新计时，慢但在动的传输永远不会被掐。
 *
 * 为什么 iroh 自己兜不住：iroh 1.0.x 给连接开了 5 s 心跳（keep-alive），连接级
 * 空闲判死是 30 s（noq 默认 max_idle_timeout；relay 路径 RELAY_PATH_MAX_IDLE_TIMEOUT
 * 同为 30 s）。所以「对端整机没了」iroh 会在 ~30 s 内让 readExact 报错（落
 * [DownloadTruncated]）；但「对端进程活着、这条流却不再发字节」时心跳一直在，连接
 * 永远不空闲，readExact 永远不返回——这一层只能由应用判。
 *
 * 为什么是 60 s：必须明显大于 iroh 的 30 s 空闲窗——relay 断线重连 / 路径切换期间
 * 合法的零字节空窗可以接近 30 s，阈值贴着它会和 iroh 的恢复抢跑；取 2 倍。与桌面拉取
 * 的 FETCH_BYTE_STALL_LIMIT（crates/daemon/src/flow_delivery.rs，NET-29 #504）同值、
 * 同语义（接收方亲眼看字节停没停），两者各管一条 lane，不联动。手机备份交付的
 * BYTE_STALL_THRESHOLD_MS（180 s）是另一条 lane，要比桌面晚放弃，与此无关。
 * 禁止按文件大小/速率动态推算。
 */
internal const val DOWNLOAD_BYTE_STALL_MS = 60_000L

/**
 * 每次向流要的字节数。readExact 要凑满才返回，所以它也是看门狗能看见的「进展」粒度：
 * 60 s 内凑不满一块才会判停滞，即只有低于 16 KiB/60 s（≈270 B/s）的链路会被当成死的。
 * 用 256 KiB 时这条线是 ≈4.4 KB/s——慢速蜂窝 + relay 会被误杀。
 */
private const val CHUNK: Long = 16L * 1024

/**
 * 字节停滞：连续 [stalledMs] 没收到新字节。[total] 为 null 表示还在等响应头。
 * 不是 CancellationException——必须像其它下载失败一样落到界面既有的失败出口。
 */
class DownloadStalled(val received: Long, val total: Long?, val stalledMs: Long) :
    AssetDownloadException(
        "download stalled: no new bytes for ${stalledMs}ms " +
            "(received $received of ${total ?: "?"} bytes)"
    )

/**
 * NET-09（#116）字节停滞看门狗。每次读都单独计时（= 每收到一块就重置）。
 *
 * 打断方式（NET-28 #454 的教训）：不靠取消正在读的那个协程——若读卡在原生阻塞调用里，
 * 协程取消打断不了它。读放到一个与调用方脱钩的协程里跑，调用方只在「等结果」这一步
 * 限时；超时即调 [abort]（生产里 = 同步关闭 iroh 连接，让卡住的 readExact 报错返回、
 * 释放线程），然后立刻抛 [DownloadStalled]，不等那次读收尾。
 */
internal class ByteStallGuard(
    private val stallMs: Long = DOWNLOAD_BYTE_STALL_MS,
    private val abort: () -> Unit = {},
) {
    private class Got<T>(val value: T)

    suspend fun <T> read(received: Long, total: Long?, block: suspend () -> T): T {
        val pending = CoroutineScope(Dispatchers.IO).async { block() }
        val got = try {
            withTimeoutOrNull(stallMs) { Got(pending.await()) }
        } catch (e: CancellationException) {
            pending.cancel()
            throw e
        }
        if (got != null) return got.value
        runCatching(abort)
        pending.cancel()
        throw DownloadStalled(received, total, stallMs)
    }
}

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
    stall: ByteStallGuard = ByteStallGuard(),
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
                    stall.read(received, total) { readChunk(want.toUInt()) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: DownloadStalled) {
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
