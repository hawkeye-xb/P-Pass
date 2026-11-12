// 卡 #124（MOB-73）：查看本机已备份的照片时优先读本机相册。
//
// 方案「丙」（产品负责人 2026-11-12 定）：用账本现有只读接口
// `readCurrentOrders` 把「当前行、已确认、有指纹、原图还在」的条目读一遍，
// 在内存里建「内容指纹 → 相册记录号」映射；不落盘、不改账本、不碰核心路径。
// 冷启动多一次全表顺序读（只读，几千行，毫秒级）。
//
// 安全约束（卡上的硬性要求）：本机相册地址（`content://…`）与相册记录号
// （`mediaId`）只在本机使用——它们只出现在 [LocalFirstOriginals] 内部，
// 任何上行调用（缩略图请求、原图下载）只拿内容指纹与目标文件。这个文件
// 也没有别的出网路径。
package com.hawkeyexb.ppass.ui

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import com.hawkeyexb.ppass.backup.flow.liveFlowRuntime
import com.hawkeyexb.ppass.backup.flow.sourceVersionOf
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.ThumbSize
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** 账本里一条可用的本机原图：相册记录号 + 建账时记下的版本（`修改时间:字节数`）。 */
internal data class LocalOriginal(val mediaId: Long, val sourceVersion: String)

/** 内容指纹 → 本机原图。[EMPTY] = 没有可用的本机来源，一律走远端。 */
internal class LocalSourceIndex private constructor(private val byHash: Map<String, LocalOriginal>) {
    fun find(hash: String): LocalOriginal? = byHash[hash]

    val hasEntries: Boolean get() = byHash.isNotEmpty()

    companion object {
        val EMPTY = LocalSourceIndex(emptyMap())

        /**
         * 只收「已确认、有内容指纹、原图还在」的条目（传进来的行已由
         * [com.hawkeyexb.ppass.backup.order.OrderStore.readCurrentOrders] 去重成当前行）。
         *
         * 同一个指纹有多行（同一张照片落在多个相册、或历史上传过多版）时取 mediaId
         * 最大的那条：结果稳定；具体哪一条能用还要过 [OriginalReader] 的版本核对，
         * 选错只是回退远端，不会显示错的照片。
         */
        fun of(orders: Sequence<Order>): LocalSourceIndex {
            val out = HashMap<String, LocalOriginal>()
            for (order in orders) {
                val hash = order.contentHash?.takeIf { it.isNotBlank() } ?: continue
                if (order.state != OrderState.CONFIRMED || order.sourceMissing) continue
                val seen = out[hash]
                if (seen == null || order.mediaId > seen.mediaId) {
                    out[hash] = LocalOriginal(order.mediaId, order.sourceVersion)
                }
            }
            return if (out.isEmpty()) EMPTY else LocalSourceIndex(out)
        }
    }
}

/** 本机相册地址：按资产类型选 images / video 集合（记录号只在各自的集合里有意义）。 */
internal fun localMediaUri(mediaType: String, mediaId: Long): String =
    if (mediaType.startsWith("video")) "content://media/external/video/media/$mediaId"
    else "content://media/external/images/media/$mediaId"

/** 空索引（账本运行时还没起来 / 还没备份过）隔这么久重读一次。 */
internal const val LOCAL_INDEX_EMPTY_RETRY_MS = 5_000L

/** 有内容时多久重读一次（新备份的照片才会进映射；旧条目过期只是回退远端）。 */
internal const val LOCAL_INDEX_REFRESH_MS = 60_000L

/** [loadedAtMs] 为 null = 还没读过。纯函数，JVM 可测。 */
internal fun localIndexReloadDue(nowMs: Long, loadedAtMs: Long?, hasEntries: Boolean): Boolean =
    loadedAtMs == null ||
        nowMs - loadedAtMs >= (if (hasEntries) LOCAL_INDEX_REFRESH_MS else LOCAL_INDEX_EMPTY_RETRY_MS)

/**
 * 打开本机相册地址、核对版本、读出内容。Android 实现在 [AndroidOriginalReader]，
 * JVM 单测用假实现（android.graphics.Bitmap / MediaStore 在本地单测里跑不了）。
 */
internal interface OriginalReader<T> {
    /** 核对一致 → 原图解码出的图（长边不超过 [maxPx]）；读不到 / 核对不上 → null。 */
    suspend fun thumb(uri: String, sourceVersion: String, maxPx: Int): T?

    /** 核对一致 → 把原图复制到 [dest]；读不到 / 核对不上 → false（不留下半个文件）。 */
    suspend fun copy(uri: String, sourceVersion: String, dest: File): Boolean
}

/**
 * 丙案的内存映射 + 读取：索引按 [localIndexReloadDue] 的节奏从账本重读，命中后
 * 交给 [reader] 打开并核对。任何一步不成立都返回「没找到」，由调用方回退远端。
 */
internal class LocalFirstOriginals<T>(
    private val reader: OriginalReader<T>,
    private val loadIndex: suspend () -> LocalSourceIndex,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private var index: LocalSourceIndex = LocalSourceIndex.EMPTY
    private var loadedAtMs: Long? = null

    /** 当前的内存映射（必要时先从账本重读）。 */
    suspend fun currentIndex(): LocalSourceIndex = mutex.withLock {
        val now = clock()
        if (localIndexReloadDue(now, loadedAtMs, index.hasEntries)) {
            index = runCatching { loadIndex() }.getOrDefault(LocalSourceIndex.EMPTY)
            loadedAtMs = now
        }
        index
    }

    suspend fun thumb(asset: AssetMeta, maxPx: Int): T? =
        withLocal(asset) { uri, version -> reader.thumb(uri, version, maxPx) }

    suspend fun copy(asset: AssetMeta, dest: File): Boolean =
        withLocal(asset) { uri, version -> reader.copy(uri, version, dest) } ?: false

    private suspend fun <R : Any> withLocal(asset: AssetMeta, block: suspend (String, String) -> R?): R? {
        val hit = currentIndex().find(asset.hash) ?: return null
        return block(localMediaUri(asset.mediaType, hit.mediaId), hit.sourceVersion)
    }
}

/**
 * 查看器的取图出口：来源是本机、账本命中、版本核对一致 → 读本机；其它情况
 * （来源不是本机、账本没有、权限没了、核对不上）一律走原来的远端路径，不报错、
 * 不提示降级。远端调用只接收内容指纹与目标文件——`content://` 地址与 mediaId
 * 不出 [LocalFirstOriginals] 这一层。
 */
internal class LocalFirstLoader<T>(
    private val local: LocalFirstOriginals<T>,
    private val remoteThumb: suspend (hash: String, size: ThumbSize) -> T?,
    private val remoteDownload: suspend (hash: String, dest: File) -> Unit,
) {
    /** 缩略图 / 大图：本机命中给本机那份，否则老路。 */
    suspend fun thumb(asset: AssetMeta, size: ThumbSize, isMine: Boolean): T? {
        if (isMine) runCatching { local.thumb(asset, size.px) }.getOrNull()?.let { return it }
        return remoteThumb(asset.hash, size)
    }

    /** RET-01：保存 / 分享共用——本机命中就复制到 [dest]，否则按老路下载到 [dest]。 */
    suspend fun fetchOriginal(asset: AssetMeta, isMine: Boolean, dest: File): File {
        if (isMine && runCatching { local.copy(asset, dest) }.getOrDefault(false)) return dest
        remoteDownload(asset.hash, dest)
        return dest
    }
}

/**
 * Android 实现：MediaStore 地址 → 核对版本 → 解码 / 复制。
 * 没有相册权限、行已不在、版本对不上，一律当「没找到」——回退远端，不抛给界面。
 */
internal class AndroidOriginalReader(private val context: Context) : OriginalReader<Bitmap> {
    private val resolver: ContentResolver get() = context.contentResolver

    override suspend fun thumb(uri: String, sourceVersion: String, maxPx: Int): Bitmap? =
        withContext(Dispatchers.IO) {
            runCatching {
                val target = Uri.parse(uri)
                if (!versionMatches(target, sourceVersion)) return@runCatching null
                decodeDownscaled(target, maxPx)
            }.getOrNull()
        }

    override suspend fun copy(uri: String, sourceVersion: String, dest: File): Boolean =
        withContext(Dispatchers.IO) {
            val copied = runCatching {
                val target = Uri.parse(uri)
                if (!versionMatches(target, sourceVersion)) return@runCatching false
                resolver.openInputStream(target)?.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                } ?: return@runCatching false
                true
            }.getOrDefault(false)
            if (!copied) runCatching { dest.delete() }
            copied
        }

    /** 卡 #124 第 2 步：打开后核对大小与修改时间，必须和账本记的那一版一致。 */
    private fun versionMatches(uri: Uri, expected: String): Boolean = runCatching {
        resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE),
            null,
            null,
            null,
        )?.use { row ->
            row.moveToFirst() && sourceVersionOf(row.getLong(0), row.getLong(1)) == expected
        } ?: false
    }.getOrDefault(false) // 没有相册权限（SecurityException）/ 行已不在 → 当没找到

    private fun decodeDownscaled(uri: Uri, maxPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxPx)
        }
        return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    }
}

/** 2 的幂采样，解码后长边不超过 [maxPx]（BitmapFactory 只认 2 的幂）。纯函数，JVM 可测。 */
internal fun sampleSizeFor(width: Int, height: Int, maxPx: Int): Int {
    if (width <= 0 || height <= 0 || maxPx <= 0) return 1
    var sample = 1
    while (maxOf(width, height) / sample > maxPx) sample *= 2
    return sample
}

/**
 * 账本只读快照：运行时还没起来（未配对 / 构建中）就是空索引，下次查找按
 * [localIndexReloadDue] 再试。不在这里触发运行时构建——查看照片不该等原生仓库初始化。
 */
internal fun readLocalSourceIndex(): LocalSourceIndex =
    liveFlowRuntime()?.store?.readCurrentOrders { LocalSourceIndex.of(it) } ?: LocalSourceIndex.EMPTY
