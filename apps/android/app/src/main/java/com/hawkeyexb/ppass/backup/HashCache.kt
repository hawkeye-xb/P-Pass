// PERF-01: 备份哈希缓存——同一张没变过的照片只在第一次备份时读流哈希
// 一次，之后手动/自动备份的 hash 阶段命中缓存（秒级），千张库不再分钟级
// 卡在 Hashing（T6 把手动备份改成 since=0 全量重扫+全量重哈希后的回归）。
//
// key = (MediaStore _ID, 修改信号)：API 30+ 用 GENERATION_MODIFIED
// （任何编辑都会 bump）；API<30 退 DATE_MODIFIED + SIZE（DATE_ADDED
// 编辑不变，必须带修改时间兜底）。value = blake3 hex（与 daemon 端
// 位级一致，见 Blake3VectorTest）。
//
// 持久化 filesDir/hash-cache.json（tmp+rename 崩溃安全，损坏当空不崩，
// 与 ConfirmedStore 同款套路）。flush() 在 hash 阶段末调用一次——中途
// 崩溃最多丢本次增量（下次重算，正确性不受影响，只是慢）。
//
// 清理策略：跟随 MediaStore 现存 _ID 集合（prune），校准时刻
// （App 打开 / 每次备份前）清孤儿；MediaStore 查询失败则跳过，下次再清。
package com.hawkeyexb.ppass.backup

import android.content.Context
import java.io.File
import java.io.InputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class HashCacheState(
    val entries: Map<String, String> = emptyMap(),
)

/** filesDir/hash-cache.json。hash 是内容身份，跨 remote 通用——不放
 *  per-remote 目录（与 ConfirmedStore 的 backup-state/<remoteId>/ 不同），
 *  断开配对不清理它（重配对后缓存依然有效）。 */
fun hashCacheFile(context: Context): File = File(context.filesDir, "hash-cache.json")

/** PERF-01: cache key。API 30+ 用 GENERATION_MODIFIED；API<30 退
 *  DATE_MODIFIED + SIZE。uri 前缀带 collection，避免 images/videos 两个
 *  collection 的 _ID 撞号（ContentUris.withAppendedId 的 uri 字符串即
 *  集合+ID 的唯一标识）。 */
fun hashCacheKey(
    uri: String,
    generation: Long,
    dateModified: Long,
    bytes: Long,
    api30Plus: Boolean,
): String = if (api30Plus) "$uri|g$generation" else "$uri|m$dateModified|s$bytes"

/** PERF-01: 缓存优先的 hash——命中直接返回，miss 才 open 重算并回写。
 *  [open] 是内容源工厂（生产 = resolver.openInputStream，测试注入
 *  可计数工厂）。 */
fun hashWithCache(cache: HashCache, key: String, open: () -> InputStream): String {
    cache.get(key)?.let { return it }
    return open().use { blake3Hex(it) }.also { cache.put(key, it) }
}

/** PERF-01: 孤儿清理——MediaStore 现存 uri 集合之外的条目删除
 *  （照片被删/相册被清）。MediaStore 查询失败则跳过（缓存保留，下次
 *  再清），绝不因清理失败影响备份。 */
internal fun pruneHashCache(context: Context) {
    try {
        val cache = HashCache(hashCacheFile(context))
        val valid = MediaScanner(context.contentResolver).allItemUris()
        cache.prune(valid)
    } catch (_: Throwable) {
    }
}

/** 哈希缓存：key → blake3 hex。内存态 + 显式 flush 落盘。 */
class HashCache(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true }
    private var memory: MutableMap<String, String> = load()

    private fun load(): MutableMap<String, String> =
        if (file.isFile) {
            try {
                json.decodeFromString(HashCacheState.serializer(), file.readText())
                    .entries.toMutableMap()
            } catch (_: Exception) {
                mutableMapOf() // 损坏则当空缓存（不崩）
            }
        } else mutableMapOf()

    fun get(key: String): String? = memory[key]

    fun put(key: String, hash: String) {
        memory[key] = hash
    }

    /** 条目数（清理阈值判断用）。 */
    fun size(): Int = memory.size

    /** tmp+rename 落盘（hash 阶段末调用一次；重开 App 读盘恢复命中）。 */
    fun flush() {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(json.encodeToString(HashCacheState.serializer(), HashCacheState(memory)))
        check(tmp.renameTo(file)) { "cannot persist hash cache" }
    }

    /** 只保留 uri 前缀在 [validUris] 里的条目；无变化则不动盘。 */
    fun prune(validUris: Set<String>) {
        val kept = memory.filterKeys { it.substringBefore('|') in validUris }.toMutableMap()
        if (kept.size != memory.size) {
            memory = kept
            flush()
        }
    }
}
