package com.hawkeyexb.ppass.ui

import android.graphics.Bitmap
import android.util.Base64
import android.util.LruCache
import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.ThumbGet
import com.hawkeyexb.ppass.proto.ThumbSize
import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PeerAddrParts
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test

class ThumbPlaceholderCacheTest {

    private lateinit var backing: LinkedHashMap<String, Bitmap>
    private lateinit var fakeCache: LruCache<String, Bitmap>

    private val daemon = PeerAddrParts(
        idHex = "a".repeat(64),
        relayUrl = null,
        directAddresses = emptyList(),
    )
    private val hash = "b".repeat(64)
    private val placeholderBytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x01)
    private val realBytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x02)
    private val placeholderB64 = java.util.Base64.getEncoder().encodeToString(placeholderBytes)
    private val realB64 = java.util.Base64.getEncoder().encodeToString(realBytes)

    @Before
    fun setUp() {
        backing = LinkedHashMap()
        fakeCache = mockk()
        every { fakeCache.get(any()) } answers { backing[firstArg()] }
        every { fakeCache.put(any(), any()) } answers { backing.put(firstArg(), secondArg()) }
        every { fakeCache.remove(any()) } answers { backing.remove(firstArg()) }
        every { fakeCache.evictAll() } answers { backing.clear() }
        every { fakeCache.snapshot() } answers { LinkedHashMap(backing) }

        mockkStatic("com.hawkeyexb.ppass.ui.PhotosScreenKt")
        every { thumbCache } returns fakeCache

        mockkStatic(Base64::class)
        every { Base64.decode(any<String>(), any()) } answers {
            java.util.Base64.getDecoder().decode(firstArg<String>())
        }

        mockkStatic("com.hawkeyexb.ppass.ui.DesktopThumbKt")
    }

    @After
    fun tearDown() {
        unmockkStatic("com.hawkeyexb.ppass.ui.DesktopThumbKt")
        unmockkStatic(Base64::class)
        unmockkStatic("com.hawkeyexb.ppass.ui.PhotosScreenKt")
    }

    @Test
    fun placeholderThumbIsNotCachedAndSubsequentCallFetchesRealThumb() = runBlocking {
        val placeholderBmp = mockk<Bitmap>(name = "placeholderBmp")
        val realBmp = mockk<Bitmap>(name = "realBmp")
        every { decodeDesktopThumb(any(), any(), any()) } answers {
            if (firstArg<ByteArray>().contentEquals(placeholderBytes)) placeholderBmp else realBmp
        }

        val client = mockk<DaemonClient>()
        var rpcCalls = 0
        coEvery { client.call(daemon, Methods.THUMB_GET, any(), any()) } coAnswers {
            rpcCalls++
            val payload = if (rpcCalls == 1) {
                """{"jpeg_base64":"$placeholderB64","placeholder":true,"retry_after_ms":600000}"""
            } else {
                """{"jpeg_base64":"$realB64"}"""
            }
            Resp(ok = true, result = ProtoJson.parseToJsonElement(payload))
        }

        val loader = TimelineLoader(client, daemon) {}

        val first = loader.thumb(hash, ThumbSize.S256)
        assertNull("服务端返回 placeholder=true 时必须返回 null，走骨架态", first)
        assertNull("placeholder=true 严禁写入 thumbCache", backing["$hash/256"])
        assertEquals(1, rpcCalls)
        verify(exactly = 0) { decodeDesktopThumb(any(), any(), any()) }

        val second = loader.thumb(hash, ThumbSize.S256)
        assertSame("服务端后续返回真图（placeholder=false）应解码并返回真图", realBmp, second)
        assertSame("真图必须写入 thumbCache", realBmp, backing["$hash/256"])
        assertEquals("首次未入缓存，二次必须重新发起 thumb.get RPC", 2, rpcCalls)

        val third = loader.thumb(hash, ThumbSize.S256)
        assertSame("真图已缓存后三次应直接命中缓存", realBmp, third)
        assertEquals("命中真图缓存后不得重复发 RPC", 2, rpcCalls)
    }

    @Test
    fun placeholderLargeThumbIsNotCachedEither() = runBlocking {
        val placeholderBmp = mockk<Bitmap>(name = "placeholderLargeBmp")
        val realBmp = mockk<Bitmap>(name = "realLargeBmp")
        every { decodeDesktopThumb(any(), any(), any()) } answers {
            if (firstArg<ByteArray>().contentEquals(placeholderBytes)) placeholderBmp else realBmp
        }

        val client = mockk<DaemonClient>()
        var rpcCalls = 0
        coEvery { client.call(daemon, Methods.THUMB_GET, any(), any()) } coAnswers {
            rpcCalls++
            val payload = if (rpcCalls == 1) {
                """{"jpeg_base64":"$placeholderB64","placeholder":true,"retry_after_ms":600000}"""
            } else {
                """{"jpeg_base64":"$realB64","placeholder":false}"""
            }
            Resp(ok = true, result = ProtoJson.parseToJsonElement(payload))
        }

        val loader = TimelineLoader(client, daemon) {}

        assertNull("1024 大图预览收到 placeholder=true 同样不得返回或缓存", loader.thumb(hash, ThumbSize.S1024))
        assertNull(backing["$hash/1024"])
        assertEquals(1, rpcCalls)

        assertSame(realBmp, loader.thumb(hash, ThumbSize.S1024))
        assertSame(realBmp, backing["$hash/1024"])
        assertEquals(2, rpcCalls)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun pullToRefreshRetriesNullTileWithoutRefetchingLoadedTiles() = runTest {
        val pendingHash = "c".repeat(64)
        val readyHash = "d".repeat(64)
        val localHash = "e".repeat(64)
        val pendingRealBmp = mockk<Bitmap>(name = "pendingRealBmp")
        val readyRealBmp = mockk<Bitmap>(name = "readyRealBmp")
        val localBmp = mockk<Bitmap>(name = "localBmp")
        val placeholderBmp = mockk<Bitmap>(name = "placeholderBmp")

        val pendingBytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x11)
        val readyBytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x22)
        val pendingB64 = java.util.Base64.getEncoder().encodeToString(pendingBytes)
        val readyB64 = java.util.Base64.getEncoder().encodeToString(readyBytes)

        every { decodeDesktopThumb(any(), any(), any()) } answers {
            val bytes = firstArg<ByteArray>()
            when {
                bytes.contentEquals(placeholderBytes) -> placeholderBmp
                bytes.contentEquals(pendingBytes) -> pendingRealBmp
                bytes.contentEquals(readyBytes) -> readyRealBmp
                else -> null
            }
        }

        val client = mockk<DaemonClient>()
        val rpcCountByHash = mutableMapOf<String, Int>()
        coEvery { client.call(daemon, Methods.THUMB_GET, any(), any()) } coAnswers {
            val req = ProtoJson.decodeFromJsonElement(ThumbGet.serializer(), arg<JsonElement>(2))
            val n = (rpcCountByHash[req.hash] ?: 0) + 1
            rpcCountByHash[req.hash] = n
            val payload = when {
                req.hash == pendingHash && n == 1 ->
                    """{"jpeg_base64":"$placeholderB64","placeholder":true,"retry_after_ms":600000}"""
                req.hash == pendingHash ->
                    """{"jpeg_base64":"$pendingB64"}"""
                else ->
                    """{"jpeg_base64":"$readyB64"}"""
            }
            Resp(ok = true, result = ProtoJson.parseToJsonElement(payload))
        }

        val loader = TimelineLoader(client, daemon) {}
        val sameAssets = listOf(
            AssetMeta(hash = pendingHash, mediaType = "photo", bytes = 10),
            AssetMeta(hash = readyHash, mediaType = "photo", bytes = 20),
        )
        val release = CompletableDeferred<Unit>()
        val channel = object : TimelineChannel {
            override val loader: TimelineLoader = loader
            override suspend fun loadPage(cursor: String?): TimelinePage = TimelinePage(items = sameAssets)
            override suspend fun subscribe(onConnected: suspend () -> Unit, onInvalidated: suspend () -> Unit) {
                onConnected()
                release.await()
            }
            override fun onRefreshed(hashes: Set<String>) = loader.onTimelineRefreshed(hashes)
            override fun onAppended(hashes: Set<String>) = loader.onTimelineAppended(hashes)
        }
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = {
                Pairing(
                    daemonNodeId = "a".repeat(64),
                    daemonAddrToken = "tok",
                    storageDeviceName = "Test",
                )
            },
            channelFor = { channel },
        )

        holder.start()
        runCurrent()
        val gen1 = holder.refreshGeneration
        assertEquals(1, gen1)

        // 首轮渲染：pending 收到占位图停留在 null，ready 命中真图，local 仅在状态里持有本机图（不进 thumbCache）。
        var pendingTileBmp = resolveThumbTile(current = null, cacheKey = "$pendingHash/256", cached = fakeCache::get) {
            loader.thumb(pendingHash, ThumbSize.S256)
        }
        var readyTileBmp = resolveThumbTile(current = null, cacheKey = "$readyHash/256", cached = fakeCache::get) {
            loader.thumb(readyHash, ThumbSize.S256)
        }
        var localTileFetches = 0
        var localTileBmp = resolveThumbTile(current = null, cacheKey = "$localHash/256", cached = fakeCache::get) {
            localTileFetches++
            localBmp
        }
        assertNull(pendingTileBmp)
        assertSame(readyRealBmp, readyTileBmp)
        assertSame(localBmp, localTileBmp)
        assertEquals(1, rpcCountByHash[pendingHash])
        assertEquals(1, rpcCountByHash[readyHash])
        assertEquals(1, localTileFetches)

        // 下拉刷新返回完全相同的 hash 集合，refreshGeneration 仍递增，驱动停留在 null 的格子重拉。
        holder.refresh()
        runCurrent()
        assertEquals("下拉刷新即使 hash 列表不变也必须推进 refreshGeneration", gen1 + 1, holder.refreshGeneration)

        // 模拟 produceState(key1 = asset.hash, key2 = refreshGeneration) 在代际变化后重跑：
        pendingTileBmp = resolveThumbTile(current = pendingTileBmp, cacheKey = "$pendingHash/256", cached = fakeCache::get) {
            loader.thumb(pendingHash, ThumbSize.S256)
        }
        readyTileBmp = resolveThumbTile(current = readyTileBmp, cacheKey = "$readyHash/256", cached = fakeCache::get) {
            loader.thumb(readyHash, ThumbSize.S256)
        }
        localTileBmp = resolveThumbTile(current = localTileBmp, cacheKey = "$localHash/256", cached = fakeCache::get) {
            localTileFetches++
            localBmp
        }

        assertSame("停留在 null 的格子下拉刷新后应重新拉取并拿到真图", pendingRealBmp, pendingTileBmp)
        assertSame(pendingRealBmp, backing["$pendingHash/256"])
        assertEquals("pending 格子必须发起第二次 thumb.get RPC", 2, rpcCountByHash[pendingHash])

        assertSame("已加载真图的格子刷新后保持原图零闪烁", readyRealBmp, readyTileBmp)
        assertEquals("已加载真图的格子不得重发 RPC", 1, rpcCountByHash[readyHash])

        assertSame("已加载本机缩略图的格子刷新后不得重复解码", localBmp, localTileBmp)
        assertEquals(1, localTileFetches)
    }
}
