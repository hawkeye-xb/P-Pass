// ARCH-13 (#417): 测试用 MediaStore。语义与 ContentResolverMediaSnapshotSource 相同：
// readAll = 全量（不按相册过滤，#416 裁决 1），按 _id 升序；readChangedSince = 该卷上范围内、generation > G，
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
    val hashed = mutableListOf<Long>()
    var versions: Map<String, String> = mapOf(LEGACY_VOLUME to "v1")

    fun put(photo: FakePhoto) {
        photos.removeAll { it.mediaId == photo.mediaId }
        photos += photo
    }

    fun remove(mediaId: Long) {
        photos.removeAll { it.mediaId == mediaId }
    }

    /** 与生产 hasher 同样的失败语义：照片没了抛 [java.io.FileNotFoundException]。 */
    fun hash(mediaId: Long): String {
        hashed += mediaId
        val p = photos.singleOrNull { it.mediaId == mediaId } ?: throw java.io.FileNotFoundException("media $mediaId gone")
        return p.hash
    }

    fun inScope(bucketId: Long): Boolean = scope?.contains(bucketId) == true

    override fun <R> readAll(block: (Sequence<MediaSnapshot>) -> R): R =
        block(photos.sortedBy { it.mediaId }.map { it.snapshot }.asSequence())

    override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, block: (Sequence<MediaSnapshot>) -> R): R =
        block(
            photos.filter { it.volume == volumeName && it.generation > afterGeneration && inScope(it.bucketId) }
                .sortedWith(compareBy({ it.generation }, { it.mediaId }))
                .map { it.snapshot }
                .asSequence(),
        )

    override fun volumeNames(): List<String> = (photos.map { it.volume } + LEGACY_VOLUME).distinct().sorted()

    override fun volumeVersions(): Map<String, String> = versions

    override fun lookup(mediaId: Long): MediaDetails? =
        photos.singleOrNull { it.mediaId == mediaId }?.let {
            MediaDetails(it.snapshot, "content://media/external/file/${it.mediaId}", "IMG_${it.mediaId}.jpg", "image/jpeg", it.size, 0L)
        }
}
