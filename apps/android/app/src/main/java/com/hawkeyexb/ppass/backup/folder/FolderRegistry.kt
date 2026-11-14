// #1762 本地授权目录来源：来源与文件映射的注册表（对位 iOS FolderRegistry，ADR §2 SourceRegistry）。
// 保存 sourceId、显示名、SAF 树 URI、授权状态与 opaque itemId ↔ 相对路径的私有映射，跨启动恢复。
// 目录树 URI 与完整相对路径只放在这里（App 私有容器）：不写日志、不进 order、不进审计 itemRef、不上协议。
//
// 与 iOS 的关键差异：Android 的 order 表 media_id / bucket_id 是 Long（SQLite INTEGER），
// 目录来源的字符串 ID 不能直接进 order。这里用「私有映射」把字符串 ID 映射到 Long：
//   - sourceId（UUID 字符串）→ bucketId（Long，bit 62 置位）
//   - opaque itemId（字符串）→ mediaId（Long，bit 62 置位）
// bit 62 置位 = 目录命名空间；MediaStore 的 `_id` 是 AUTOINCREMENT 的小正整数，永不撞上 2^62。
// 不改 backup/order/** 的 INTEGER 格式，也不改扫描游标从 0 起步的语义（负 ID 会被 `_id > 0` 漏掉）。
package com.hawkeyexb.ppass.backup.folder

import com.hawkeyexb.ppass.io.atomicReplace
import java.io.File
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** 目录命名空间标志：bit 62 置位 = 目录来源 / 目录项。 */
const val FOLDER_ID_FLAG = 0x4000000000000000L

/** 这个 Long 是不是目录命名空间里的 ID（bucketId 或 mediaId）。 */
fun isFolderId(id: Long): Boolean = (id and FOLDER_ID_FLAG) != 0L

/** 一个已登记的目录来源（持久化形状）。 */
@Serializable
data class FolderRecord(
    /** 稳定 UUID；移除后不复用（[FolderRegistry.removedIds] 防复用）。 */
    val id: String,
    val displayName: String,
    /** SAF 树 URI（用户经目录选择器授权时拿到的 persistable URI）。 */
    val treeUri: String,
    /** 分配的 Long bucketId（bit 62 置位，进 order 表）。 */
    val bucketId: Long,
    /** 登记成功 = registered；授权失效待恢复 = recoveryUnverified。 */
    val status: String = STATUS_REGISTERED,
    /** opaque itemId → 文件项（相对路径 + 分配的 mediaId）。 */
    val items: Map<String, FolderItem> = emptyMap(),
) {
    companion object {
        const val STATUS_REGISTERED = "registered"
        const val STATUS_RECOVERY_UNVERIFIED = "recoveryUnverified"
    }
}

/** 目录里一个文件项的私有映射：相对路径 + 分配的 Long mediaId。 */
@Serializable
data class FolderItem(
    /** 规范化相对路径（`/` 分隔、不含 `.` / `..` 段）。 */
    val relativePath: String,
    /** 分配的 Long mediaId（bit 62 置位）。 */
    val mediaId: Long,
)

/** 相对路径的语法规范化（ADR §3）：分隔符与 `.` 段处理，拒绝绝对路径和 `..`；不折叠 Unicode、不判等大小写。 */
object FolderPaths {
    fun normalize(raw: String): String? {
        if (raw.startsWith("/")) return null
        val parts = ArrayList<String>()
        for (part in raw.split("/")) {
            if (part.isEmpty() || part == ".") continue
            if (part == "..") return null
            parts.add(part)
        }
        if (parts.isEmpty()) return null
        return parts.joinToString("/")
    }

    /** 路径判等按字节（与 mediaId 判等同一口径），不折叠 Unicode。 */
    fun same(a: String, b: String): Boolean = a == b
}

/**
 * 来源注册表：App 私有 JSON（单文件、原子写）。一个进程一个实例；跨启动恢复靠重读文件。
 * 线程安全：所有读写都在锁内；FlowEngine 写者线程与 UI 列表读共用。
 */
class FolderRegistry(private val file: File) {
    private val lock = Any()
    private var nextId: Long
    private var sources: MutableMap<String, FolderRecord>
    private var removedIds: MutableSet<String>

    init {
        val loaded = runCatching { Json.decodeFromString<Persisted>(file.readText()) }.getOrNull()
        nextId = loaded?.nextId ?: 1L
        sources = (loaded?.sources ?: emptyList()).associateByTo(LinkedHashMap()) { it.id }
        removedIds = (loaded?.removedIds ?: emptyList()).toMutableSet()
    }

    @Serializable
    private data class Persisted(
        val nextId: Long,
        val sources: List<FolderRecord>,
        val removedIds: List<String>,
    )

    private fun persistLocked(): Boolean = try {
        file.parentFile?.mkdirs()
        val json = Json.encodeToString(Persisted(nextId, sources.values.sortedBy { it.id }, removedIds.sorted()))
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(json)
        check(atomicReplace(tmp, file)) { "cannot persist folder registry" }
        true
    } catch (failure: Exception) {
        false
    }

    private fun allocateId(): Long {
        val id = FOLDER_ID_FLAG or nextId
        nextId++
        return id
    }

    /** 登记一个目录来源：分配 sourceId 与 bucketId，书签（树 URI）写失败就不启用该来源（ADR「书签保存失败：不启用」）。 */
    fun addFolder(treeUri: String, displayName: String): String {
        synchronized(lock) {
            val id = UUID.randomUUID().toString().lowercase()
            val bucketId = allocateId()
            sources[id] = FolderRecord(id = id, displayName = displayName, treeUri = treeUri, bucketId = bucketId)
            if (!persistLocked()) {
                sources.remove(id)
                throw IllegalStateException("folder registry persist failed")
            }
            return id
        }
    }

    /** 移除来源：id 进 removedIds，永不复用。只停止后续备份，不删手机素材或桌面副本。 */
    fun removeFolder(sourceId: String) {
        synchronized(lock) {
            sources.remove(sourceId)
            removedIds.add(sourceId)
            persistLocked()
        }
    }

    fun record(sourceId: String): FolderRecord? = synchronized(lock) { sources[sourceId] }

    /** 这个树 URI 是不是已经登记过（防同一目录重复添加成两个来源）。 */
    fun hasTreeUri(treeUri: String): Boolean = synchronized(lock) {
        sources.values.any { it.treeUri == treeUri }
    }

    fun allRecords(): List<FolderRecord> = synchronized(lock) { sources.values.sortedBy { it.id } }

    fun bucketIdOf(sourceId: String): Long? = synchronized(lock) { sources[sourceId]?.bucketId }

    /** 相对路径 → 现有 opaque itemId（没有则分配一个并持久化）。opaqueId 不含相对路径。 */
    fun opaqueId(sourceId: String, relativePath: String): String {
        synchronized(lock) {
            val record = sources[sourceId] ?: return ""
            for ((opaque, item) in record.items) {
                if (FolderPaths.same(item.relativePath, relativePath)) return opaque
            }
            val opaque = UUID.randomUUID().toString().lowercase()
            val mediaId = allocateId()
            val updated = record.copy(items = record.items + (opaque to FolderItem(relativePath, mediaId)))
            sources[sourceId] = updated
            persistLocked()
            return opaque
        }
    }

    /** opaque itemId → 相对路径（导入时按映射找到文件）。损坏的持久化文件若带越界路径，这里拒绝（返回 null 不导入）。 */
    fun relativePath(sourceId: String, opaqueId: String): String? {
        synchronized(lock) {
            val raw = sources[sourceId]?.items?.get(opaqueId)?.relativePath ?: return null
            val safe = FolderPaths.normalize(raw) ?: return null
            return if (FolderPaths.same(safe, raw)) safe else null
        }
    }

    /** opaque itemId → 分配的 Long mediaId。 */
    fun mediaIdOf(sourceId: String, opaqueId: String): Long? =
        synchronized(lock) { sources[sourceId]?.items?.get(opaqueId)?.mediaId }

    /** Long mediaId → sourceId（目录命名空间里才有；非目录 ID 返回 null）。 */
    fun sourceIdOfMedia(mediaId: Long): String? {
        if (!isFolderId(mediaId)) return null
        synchronized(lock) {
            for ((sourceId, record) in sources) {
                if (record.items.values.any { it.mediaId == mediaId }) return sourceId
            }
            return null
        }
    }

    /** Long mediaId → opaque itemId。 */
    fun opaqueIdOfMedia(mediaId: Long): String? {
        if (!isFolderId(mediaId)) return null
        synchronized(lock) {
            for (record in sources.values) {
                for ((opaque, item) in record.items) {
                    if (item.mediaId == mediaId) return opaque
                }
            }
            return null
        }
    }

    /**
     * 完整枚举成功后的对账：新路径分配 opaqueId + mediaId；缺席项**从映射里删除**并按 opaqueId 返回
     * （调用方按「源缺失」处理：order 侧经 [FolderRegistry] 反查不到 → existingIds 答「不在」→ 记源缺失）。
     * 只有完整枚举成功后才允许调用（「不知道」≠ 源缺失）；调用即意味着这次扫描可信。
     */
    fun reconcile(sourceId: String, observedPaths: List<String>): Set<String> {
        synchronized(lock) {
            val record = sources[sourceId] ?: return emptySet()
            val normalized = observedPaths.mapNotNull { FolderPaths.normalize(it) }
            var updated = record
            val seen = HashSet<String>()
            for (path in normalized) {
                val existing = updated.items.entries.firstOrNull { FolderPaths.same(it.value.relativePath, path) }
                if (existing != null) {
                    seen.add(existing.key)
                    continue
                }
                val opaque = UUID.randomUUID().toString().lowercase()
                val mediaId = allocateId()
                updated = updated.copy(items = updated.items + (opaque to FolderItem(path, mediaId)))
                seen.add(opaque)
            }
            val missing = updated.items.keys - seen
            if (missing.isNotEmpty()) {
                updated = updated.copy(items = updated.items.filterKeys { it !in missing })
            }
            sources[sourceId] = updated
            // 分配出的 Long mediaId 会进 order 表；落盘失败时内存里的新映射不能被下游引用（重启后对不上），
            // 回滚并抛——本轮按 UNEXPECTED_ERROR 重试，不出现「内存一套、磁盘一套」的 mediaId。
            if (!persistLocked()) {
                sources[sourceId] = record
                throw IllegalStateException("folder registry persist failed (reconcile)")
            }
            return missing
        }
    }

    /** 这个 bucketId 是不是某个**现存**目录来源的（移除后查不到 → 自动退出范围、不再对账）。 */
    fun hasBucket(bucketId: Long): Boolean = synchronized(lock) {
        if (!isFolderId(bucketId)) return@synchronized false
        sources.values.any { it.bucketId == bucketId }
    }

    /**
     * 重新授权：用户重选同一目录后换上新树 URI，恢复 registered。来源已移除返回 false（不复用）。
     * 书签写失败不启用（与 [addFolder] 同一口径）：失败时不改旧 URI，返回 false。
     */
    fun reauthorize(sourceId: String, treeUri: String): Boolean {
        synchronized(lock) {
            val record = sources[sourceId] ?: return false
            val updated = record.copy(treeUri = treeUri, status = FolderRecord.STATUS_REGISTERED)
            sources[sourceId] = updated
            if (!persistLocked()) {
                sources[sourceId] = record
                return false
            }
            return true
        }
    }

    /** 授权疑似失效（枚举失败）时标记，供二级页显示「重新授权」。来源已移除不动。 */
    fun markRecoveryUnverified(sourceId: String) {
        synchronized(lock) {
            val record = sources[sourceId] ?: return
            if (record.status == FolderRecord.STATUS_RECOVERY_UNVERIFIED) return
            sources[sourceId] = record.copy(status = FolderRecord.STATUS_RECOVERY_UNVERIFIED)
            persistLocked()
        }
    }
}
