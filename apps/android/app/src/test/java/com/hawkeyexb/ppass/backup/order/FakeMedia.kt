// ARCH-13 (#417) → #413: 测试用 MediaStore。语义与 ContentResolverMediaSnapshotSource 相同：
// readInScope = 范围内、_id > afterId，按 _id 升序；readChangedSince = 该卷上范围内、(generation, _id) > G，
// 按 (generation, _id) 升序。
package com.hawkeyexb.ppass.backup.order

import com.hawkeyexb.ppass.backup.flow.sourceVersionOf

/** MediaStore 里的一张照片：快照字段 + 它的字节内容（假 hash = "blake3:" + 内容）。 */
data class FakePhoto(
    val mediaId: Long,
    val modified: Long,
    val size: Long,
    val content: String,
    val generation: Long,
    val bucketId: Long = 7,
    val volume: String = LEGACY_VOLUME,
) {
    val snapshot get() = MediaSnapshot(mediaId, sourceVersionOf(modified, size), bucketId, generation, volume)
    val hash get() = fakeHashOf(content)
}

fun fakeHashOf(content: String): String = "blake3:$content"

class FakeMedia(photos: List<FakePhoto> = emptyList(), var scope: Set<Long>? = setOf(7L)) : MediaSnapshotSource {
    val photos: MutableList<FakePhoto> = photos.toMutableList()
    var versions: Map<String, String> = mapOf(LEGACY_VOLUME to "v1")
    override var preciseGeneration: Boolean = true

    /** 每次元数据读取（不读文件）的次数：扫描 / 计数 / 发现都算。 */
    var metadataReads = 0

    fun put(photo: FakePhoto) {
        photos.removeAll { it.mediaId == photo.mediaId }
        photos += photo
    }

    fun remove(mediaId: Long) {
        photos.removeAll { it.mediaId == mediaId }
    }

    fun inScope(bucketId: Long): Boolean = scope?.contains(bucketId) == true

    override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        metadataReads++
        return block(photos.filter { it.mediaId > afterId && inScope(it.bucketId) }.sortedBy { it.mediaId }.map { it.snapshot }.asSequence())
    }

    override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, afterMediaId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        metadataReads++
        return block(
            photos.filter {
                it.volume == volumeName && inScope(it.bucketId) &&
                    (it.generation > afterGeneration || (it.generation == afterGeneration && it.mediaId > afterMediaId))
            }
                .sortedWith(compareBy({ it.generation }, { it.mediaId }))
                .map { it.snapshot }
                .asSequence(),
        )
    }

    override fun maxGeneration(volumeName: String): Long = photos.filter { it.volume == volumeName }.maxOfOrNull { it.generation } ?: 0L

    override fun volumeNames(): List<String> = (photos.map { it.volume } + LEGACY_VOLUME).distinct().sorted()

    override fun volumeVersions(): Map<String, String> = versions

    override fun lookup(mediaId: Long): MediaDetails? =
        photos.singleOrNull { it.mediaId == mediaId }?.let {
            MediaDetails(it.snapshot, "content://media/external/file/${it.mediaId}", "IMG_${it.mediaId}.jpg", "image/jpeg", it.size, 0L, "/sdcard/DCIM/IMG_${it.mediaId}.jpg")
        }
}
