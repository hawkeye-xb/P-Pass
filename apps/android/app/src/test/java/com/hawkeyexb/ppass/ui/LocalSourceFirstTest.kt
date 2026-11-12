// 卡 #124（MOB-73）：查看本机已备份照片时优先读取本地源。
//
// 验收场景（卡上原文）：
// ① 本机来源 + 账本命中 + 能读到 + 大小/修改时间一致 → 缩略图、大图、保存、分享
//    四条路都读本机，远端 loader/download 调用次数为 0（用计数桩证明）。
// ② 非本机来源 / 账本没有 / sourceMissing / 读不了 / 核对不一致 → 全部只回退远端。
// ③ 安全：新增代码路径不把 content:// 或 mediaId 交给任何上行接口。
//
// 本文件同时盯住索引本身（只收可用行、重复指纹取谁、重读节奏）与解码采样。
// Android 的 MediaStore 读取在 AndroidOriginalReader 里，本地单测跑不了，用
// FakeReader 顶替；四条路的「读本机 / 回退」判定全在 JVM 上可判。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.ThumbSize
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LocalSourceFirstTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val version = "1700000000:4096"
    private val imageUri = "content://media/external/images/media/42"
    private val videoUri = "content://media/external/video/media/42"

    private fun order(
        mediaId: Long,
        hash: String?,
        state: OrderState = OrderState.CONFIRMED,
        sourceMissing: Boolean = false,
        sourceVersion: String = version,
    ) = Order(
        id = mediaId,
        mediaId = mediaId,
        sourceVersion = sourceVersion,
        bucketId = 7,
        contentHash = hash,
        state = state,
        attempts = 0,
        pairingId = "pairing",
        createdAtMs = 0,
        updatedAtMs = 0,
        sourceMissing = sourceMissing,
    )

    private fun photo(hash: String = "hashA", mediaType: String = "photo") =
        AssetMeta(hash = hash, mediaType = mediaType, bytes = 4096)

    /** 记录调用的假本机读取器：可以模拟「读不了 / 核对不上」。 */
    private class FakeReader : OriginalReader<String> {
        val thumbed = mutableListOf<Pair<String, Int>>()
        val versions = mutableListOf<String>()
        val copied = mutableListOf<String>()
        var thumbAvailable = true
        var copyAvailable = true

        override suspend fun thumb(uri: String, sourceVersion: String, maxPx: Int): String? {
            thumbed += uri to maxPx
            versions += sourceVersion
            return if (thumbAvailable) "local-$maxPx" else null
        }

        override suspend fun copy(uri: String, sourceVersion: String, dest: File): Boolean {
            copied += uri
            versions += sourceVersion
            if (!copyAvailable) return false
            dest.writeText("local")
            return true
        }
    }

    /** 远端桩：只记录「上行拿到了什么」。 */
    private class Remote {
        var thumbCalls = 0
        var downloadCalls = 0
        val args = mutableListOf<String>()

        val thumb: suspend (String, ThumbSize) -> String? = { hash, _ ->
            thumbCalls++
            args += hash
            "remote"
        }
        val download: suspend (String, File) -> Unit = { hash, dest ->
            downloadCalls++
            args += hash
            dest.writeText("remote")
        }
    }

    private fun loader(
        index: LocalSourceIndex,
        reader: FakeReader = FakeReader(),
        remote: Remote = Remote(),
        clock: () -> Long = { 0L },
    ) = LocalFirstLoader(
        local = LocalFirstOriginals(reader, loadIndex = { index }, clock = clock),
        remoteThumb = remote.thumb,
        remoteDownload = remote.download,
    )

    private fun hitIndex(): LocalSourceIndex = LocalSourceIndex.of(sequenceOf(order(42, "hashA")))

    // ── ① 本机命中：四条路都读本机，远端一次都不调 ──

    @Test
    fun localHitFeedsAllFourPathsWithoutTouchingRemote() = runBlocking {
        val reader = FakeReader()
        val remote = Remote()
        val media = loader(hitIndex(), reader, remote)
        val asset = photo()

        assertEquals("local-256", media.thumb(asset, ThumbSize.S256, isMine = true)) // 网格缩略图
        assertEquals("local-1024", media.thumb(asset, ThumbSize.S1024, isMine = true)) // 大图

        val saved = File(tmp.root, "asset-hashA")
        media.fetchOriginal(asset, isMine = true, dest = saved) // 保存
        assertEquals("local", saved.readText())

        val shared = File(tmp.root, "asset-hashA-share")
        media.fetchOriginal(asset, isMine = true, dest = shared) // 分享
        assertEquals("local", shared.readText())

        assertEquals("远端缩略图一次都不该调", 0, remote.thumbCalls)
        assertEquals("远端下载一次都不该调", 0, remote.downloadCalls)

        assertEquals(listOf(imageUri, imageUri), reader.thumbed.map { it.first })
        assertEquals(listOf(256, 1024), reader.thumbed.map { it.second })
        assertEquals(listOf(imageUri, imageUri), reader.copied)
        assertTrue("尺寸与修改时间按账本口径核对", reader.versions.all { it == version })
    }

    @Test
    fun videoAssetUsesVideoCollection() = runBlocking {
        val reader = FakeReader()
        val media = loader(hitIndex(), reader, Remote())

        media.thumb(photo(mediaType = "video/mp4"), ThumbSize.S256, isMine = true)

        assertEquals(listOf(videoUri), reader.thumbed.map { it.first })
    }

    // ── ② 取不到就走老路：全部只回退远端，不展示成别的照片 ──

    @Test
    fun notFromThisPhoneFallsBackToRemote() = runBlocking {
        val reader = FakeReader()
        val remote = Remote()
        val media = loader(hitIndex(), reader, remote)
        val asset = photo()

        assertEquals("remote", media.thumb(asset, ThumbSize.S256, isMine = false))
        val dest = File(tmp.root, "asset-hashA")
        media.fetchOriginal(asset, isMine = false, dest = dest)

        assertEquals(1, remote.thumbCalls)
        assertEquals(1, remote.downloadCalls)
        assertEquals("remote", dest.readText())
        assertTrue("来源不是本机时连账本都不查", reader.thumbed.isEmpty() && reader.copied.isEmpty())
    }

    @Test
    fun hashMissingFromLedgerFallsBackToRemote() = runBlocking {
        val remote = Remote()
        val media = loader(LocalSourceIndex.of(sequenceOf(order(42, "other"))), FakeReader(), remote)

        assertEquals("remote", media.thumb(photo(), ThumbSize.S1024, isMine = true))
        assertEquals(1, remote.thumbCalls)
    }

    @Test
    fun sourceMissingRowFallsBackToRemote() = runBlocking {
        val remote = Remote()
        val reader = FakeReader()
        val index = LocalSourceIndex.of(sequenceOf(order(42, "hashA", sourceMissing = true)))
        val media = loader(index, reader, remote)

        assertEquals("remote", media.thumb(photo(), ThumbSize.S256, isMine = true))
        assertEquals(1, remote.thumbCalls)
        assertTrue(reader.thumbed.isEmpty())
    }

    @Test
    fun unconfirmedRowFallsBackToRemote() = runBlocking {
        val remote = Remote()
        val index = LocalSourceIndex.of(
            sequenceOf(
                order(42, "hashA", state = OrderState.FAILED),
                order(43, "hashA", state = OrderState.TRANSFERRING),
                order(44, "hashA", state = OrderState.SKIPPED_SOURCE_MISSING),
            ),
        )
        val media = loader(index, FakeReader(), remote)

        assertEquals("remote", media.thumb(photo(), ThumbSize.S256, isMine = true))
        assertEquals(1, remote.thumbCalls)
    }

    @Test
    fun versionMismatchOrUnreadableUriFallsBackToRemote() = runBlocking {
        val reader = FakeReader().apply {
            thumbAvailable = false // 打开后核对不上（或权限没了、行没了）
            copyAvailable = false
        }
        val remote = Remote()
        val media = loader(hitIndex(), reader, remote)
        val asset = photo()

        assertEquals("remote", media.thumb(asset, ThumbSize.S1024, isMine = true))
        val dest = File(tmp.root, "asset-hashA")
        media.fetchOriginal(asset, isMine = true, dest = dest)

        assertEquals(1, remote.thumbCalls)
        assertEquals(1, remote.downloadCalls)
        assertEquals("回退远端后拿到的是远端那份", "remote", dest.readText())
    }

    // ── ③ 安全：content:// 与 mediaId 不出本机这一层 ──

    @Test
    fun localAddressAndMediaIdNeverReachAnyUplink() = runBlocking {
        val remote = Remote()
        val media = loader(hitIndex(), FakeReader(), remote)
        val asset = photo()

        media.thumb(asset, ThumbSize.S256, isMine = true)
        media.thumb(asset, ThumbSize.S1024, isMine = false)
        media.fetchOriginal(asset, isMine = true, dest = File(tmp.root, "a"))
        media.fetchOriginal(asset, isMine = false, dest = File(tmp.root, "b"))

        assertTrue("上行只拿内容指纹", remote.args.all { it == asset.hash })
        assertFalse(remote.args.any { it.contains("content://") })
        assertFalse(remote.args.any { it.contains("media") })
        assertFalse(remote.args.any { it == "42" || it == "4242" })
    }

    @Test
    fun newFileHasNoUplinkOfItsOwn() {
        // 源码守卫：新增的本机读取实现里不许出现任何上行出口（上传/协议编码）。
        // 出网只可能在 PhotosScreen 传进来的远端 lambda 里，而它只收 hash 与目标文件。
        val source = File("src/main/java/com/hawkeyexb/ppass/ui/LocalSourceIndex.kt").readText()
        for (banned in listOf("DaemonClient", "ProtoJson", "Methods.", "downloadAsset", "subscribeTimeline")) {
            assertFalse("LocalSourceIndex.kt 不应出现 $banned", source.contains(banned))
        }
    }

    // ── 索引与重读节奏 ──

    @Test
    fun indexKeepsOnlyUsableCurrentRows() {
        val index = LocalSourceIndex.of(
            sequenceOf(
                order(1, "good"),
                order(2, null), // 没导入过，没有指纹
                order(3, "   "), // 空白指纹
                order(4, "failed", state = OrderState.FAILED),
                order(5, "gone", sourceMissing = true),
                order(6, "pending", state = OrderState.PENDING),
            ),
        )

        assertNotNull(index.find("good"))
        assertNull(index.find("failed"))
        assertNull(index.find("gone"))
        assertNull(index.find("pending"))
    }

    @Test
    fun duplicateHashPicksLargestMediaId() {
        val index = LocalSourceIndex.of(
            sequenceOf(
                order(9, "dup", sourceVersion = "1:1"),
                order(5, "dup", sourceVersion = "2:2"),
                order(7, "dup", sourceVersion = "3:3"),
            ),
        )
        assertEquals(LocalOriginal(9, "1:1"), index.find("dup"))
    }

    @Test
    fun indexIsReadOnceInsideTheRefreshWindow() = runBlocking {
        var loads = 0
        val originals = LocalFirstOriginals(
            FakeReader(),
            loadIndex = { loads++; hitIndex() },
            clock = { 1_000L },
        )

        originals.thumb(photo(), 256)
        originals.thumb(photo(), 1024)
        assertEquals("同一窗口内只读一次账本", 1, loads)
    }

    @Test
    fun emptyIndexIsRetriedAndFullIndexRefreshedOnSchedule() {
        assertTrue(localIndexReloadDue(0, loadedAtMs = null, hasEntries = false))
        assertFalse(
            "空索引 5 秒内不重读",
            localIndexReloadDue(LOCAL_INDEX_EMPTY_RETRY_MS - 1, loadedAtMs = 0, hasEntries = false),
        )
        assertTrue(
            "空索引 5 秒后重读（账本运行时可能刚起来）",
            localIndexReloadDue(LOCAL_INDEX_EMPTY_RETRY_MS, loadedAtMs = 0, hasEntries = false),
        )
        assertFalse(
            "有内容的索引 60 秒内不重读",
            localIndexReloadDue(LOCAL_INDEX_REFRESH_MS - 1, loadedAtMs = 0, hasEntries = true),
        )
        assertTrue(
            "有内容的索引 60 秒后重读",
            localIndexReloadDue(LOCAL_INDEX_REFRESH_MS, loadedAtMs = 0, hasEntries = true),
        )
    }

    // ── 解码采样（大图 / 网格都用同一份原图，不能被整张吃内存） ──

    @Test
    fun sampleSizeCapsTheLongEdge() {
        assertEquals(1, sampleSizeFor(100, 80, 1024))
        assertEquals(4, sampleSizeFor(4000, 3000, 1024))
        assertEquals(16, sampleSizeFor(4000, 3000, 256))
        assertEquals("竖图按长边算", 4, sampleSizeFor(3000, 4000, 1024))
        assertEquals("异常尺寸不采样", 1, sampleSizeFor(0, 0, 1024))
    }
}
