package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.hawkeyexb.ppass.backup.flow.sourceVersionOf
import com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG
import com.hawkeyexb.ppass.backup.folder.FolderAccess
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.AssetMeta
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LocalSourceIndexSafTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var filesDir: File
    private lateinit var resolver: ContentResolver
    private lateinit var context: Context

    private fun resetFolderAccessSingleton() {
        val field = FolderAccess::class.java.getDeclaredField("instance")
        field.isAccessible = true
        field.set(FolderAccess, null)
    }

    private fun mockUri(raw: String): Uri {
        val uri = mockk<Uri>(relaxed = true)
        every { uri.toString() } returns raw
        every { Uri.parse(raw) } returns uri
        return uri
    }

    @Before
    fun setUp() {
        resetFolderAccessSingleton()
        filesDir = tmp.newFolder("app-files")
        resolver = mockk(relaxed = true)
        context = mockk(relaxed = true)
        every { context.applicationContext } returns context
        every { context.filesDir } returns filesDir
        every { context.contentResolver } returns resolver
        mockkStatic(Uri::class)
        mockkStatic(DocumentsContract::class)
    }

    @After
    fun tearDown() {
        unmockkStatic(DocumentsContract::class)
        unmockkStatic(Uri::class)
        resetFolderAccessSingleton()
    }

    private fun cursorRow(col0: Long, col1: Long): Cursor {
        val c = mockk<Cursor>(relaxed = true)
        every { c.moveToFirst() } returns true
        every { c.getLong(0) } returns col0
        every { c.getLong(1) } returns col1
        return c
    }

    private fun childrenCursor(entries: List<Pair<String, String>>): Cursor {
        val c = mockk<Cursor>(relaxed = true)
        var idx = -1
        every { c.moveToNext() } answers {
            idx++
            idx < entries.size
        }
        every { c.getString(0) } answers { entries[idx].first }
        every { c.getString(1) } answers { entries[idx].second }
        return c
    }

    @Test
    fun resolveLocalMediaUriResolvesSafFolderTreeDocumentUriAndHandlesMediaStoreAndMissing() = runBlocking {
        // 非目录 ID 走 MediaStore URI，不碰 SAF 注册表。
        assertEquals(
            "content://media/external/video/media/42",
            resolveLocalMediaUri(context, "video/mp4", 42L),
        )

        val treeRaw = "content://com.android.externalstorage.documents/tree/primary%3ABlackmagic"
        val rootDocId = "primary:Blackmagic"
        val subDocId = "primary:Blackmagic/Clips"
        val fileDocId = "primary:Blackmagic/Clips/take1.mov"
        val fileDocRaw = "content://com.android.externalstorage.documents/tree/primary%3ABlackmagic/document/primary%3ABlackmagic%2FClips%2Ftake1.mov"

        val treeUri = mockUri(treeRaw)
        val rootDocUri = mockUri("$treeRaw/document/root")
        val subDocUri = mockUri("$treeRaw/document/clips")
        val fileDocUri = mockUri(fileDocRaw)
        val rootChildrenUri = mockUri("$treeRaw/children/root")
        val subChildrenUri = mockUri("$treeRaw/children/clips")

        every { DocumentsContract.getTreeDocumentId(treeUri) } returns rootDocId
        every { DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocId) } returns rootDocUri
        every { DocumentsContract.buildDocumentUriUsingTree(treeUri, subDocId) } returns subDocUri
        every { DocumentsContract.buildDocumentUriUsingTree(treeUri, fileDocId) } returns fileDocUri
        every { DocumentsContract.getDocumentId(rootDocUri) } returns rootDocId
        every { DocumentsContract.getDocumentId(subDocUri) } returns subDocId
        every { DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, rootDocId) } returns rootChildrenUri
        every { DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, subDocId) } returns subChildrenUri

        every { resolver.query(rootChildrenUri, any(), any(), any(), any()) } answers {
            childrenCursor(listOf(subDocId to "Clips"))
        }
        every { resolver.query(subChildrenUri, any(), any(), any(), any()) } answers {
            childrenCursor(listOf(fileDocId to "take1.mov"))
        }

        val registry = FolderAccess.registry(context)
        val sourceId = registry.addFolder(treeRaw, "Blackmagic")
        val opaqueId = registry.opaqueId(sourceId, "Clips/take1.mov")
        val mediaId = registry.mediaIdOf(sourceId, opaqueId)!!

        assertEquals(fileDocRaw, resolveLocalMediaUri(context, "video/quicktime", mediaId))

        // 反证：未知 mediaId 或子目录文件缺失时返回 null。
        assertNull(resolveLocalMediaUri(context, "video/quicktime", FOLDER_ID_FLAG or 9999L))
        every { resolver.query(subChildrenUri, any(), any(), any(), any()) } answers {
            childrenCursor(emptyList())
        }
        assertNull(resolveLocalMediaUri(context, "video/quicktime", mediaId))
    }

    @Test
    fun androidOriginalReaderVerifiesDocumentsContractAndMediaStoreVersionsForPlayableUri() = runBlocking {
        val safRaw = "content://com.android.externalstorage.documents/tree/primary%3ABlackmagic/document/take1.mov"
        val safUri = mockUri(safRaw)
        val mediaRaw = "content://media/external/video/media/42"
        val mediaUri = mockUri(mediaRaw)

        every { DocumentsContract.isDocumentUri(context, safUri) } returns true
        every { DocumentsContract.isDocumentUri(context, mediaUri) } returns false

        val expectedVersion = sourceVersionOf(1_700_000_123L, 8_192L)
        // SAF COLUMN_LAST_MODIFIED 是毫秒，AndroidOriginalReader 会除以 1000L 对齐秒级口径。
        every {
            resolver.query(
                safUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )
        } returns cursorRow(1_700_000_123_456L, 8_192L)
        every {
            resolver.query(
                mediaUri,
                arrayOf(MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE),
                null,
                null,
                null,
            )
        } returns cursorRow(1_700_000_123L, 8_192L)

        val afd = mockk<AssetFileDescriptor>(relaxed = true)
        every { resolver.openAssetFileDescriptor(safUri, "r") } returns afd
        every { resolver.openAssetFileDescriptor(mediaUri, "r") } returns afd

        val reader = AndroidOriginalReader(context)
        assertEquals(safRaw, reader.playableUri(safRaw, expectedVersion))
        assertEquals(mediaRaw, reader.playableUri(mediaRaw, expectedVersion))

        // 反证 1：SAF 文档修改时间或大小变化 → 版本比对失败，返回 null 且不打开文件描述符。
        every {
            resolver.query(
                safUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )
        } returns cursorRow(1_700_000_999_000L, 8_192L)
        assertNull(reader.playableUri(safRaw, expectedVersion))
        verify(exactly = 1) { resolver.openAssetFileDescriptor(safUri, "r") }

        // 反证 2：MediaStore 大小变化 → 返回 null。
        every {
            resolver.query(
                mediaUri,
                arrayOf(MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE),
                null,
                null,
                null,
            )
        } returns cursorRow(1_700_000_123L, 4_096L)
        assertNull(reader.playableUri(mediaRaw, expectedVersion))
        verify(exactly = 1) { resolver.openAssetFileDescriptor(mediaUri, "r") }
    }

    @Test
    fun localFirstLoaderUsesProductionSafResolutionAndVersionCheckEndToEnd() = runBlocking {
        val treeRaw = "content://com.android.externalstorage.documents/tree/primary%3ACam"
        val rootDocId = "primary:Cam"
        val fileDocId = "primary:Cam/clip.mov"
        val fileDocRaw = "$treeRaw/document/clip.mov"
        val treeUri = mockUri(treeRaw)
        val rootDocUri = mockUri("$treeRaw/document/root")
        val fileDocUri = mockUri(fileDocRaw)
        val rootChildrenUri = mockUri("$treeRaw/children/root")

        every { DocumentsContract.getTreeDocumentId(treeUri) } returns rootDocId
        every { DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocId) } returns rootDocUri
        every { DocumentsContract.buildDocumentUriUsingTree(treeUri, fileDocId) } returns fileDocUri
        every { DocumentsContract.getDocumentId(rootDocUri) } returns rootDocId
        every { DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, rootDocId) } returns rootChildrenUri
        every { resolver.query(rootChildrenUri, any(), any(), any(), any()) } answers {
            childrenCursor(listOf(fileDocId to "clip.mov"))
        }

        every { DocumentsContract.isDocumentUri(context, fileDocUri) } returns true
        every {
            resolver.query(
                fileDocUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )
        } returns cursorRow(1_700_000_500_000L, 12_345L)
        every { resolver.openAssetFileDescriptor(fileDocUri, "r") } returns mockk(relaxed = true)

        val registry = FolderAccess.registry(context)
        val sourceId = registry.addFolder(treeRaw, "Cam")
        val opaqueId = registry.opaqueId(sourceId, "clip.mov")
        val mediaId = registry.mediaIdOf(sourceId, opaqueId)!!

        val index = LocalSourceIndex.of(
            sequenceOf(
                Order(
                    id = 1L,
                    mediaId = mediaId,
                    sourceVersion = sourceVersionOf(1_700_000_500L, 12_345L),
                    bucketId = registry.bucketIdOf(sourceId)!!,
                    contentHash = "safHash",
                    state = OrderState.CONFIRMED,
                    attempts = 0,
                    pairingId = "p",
                    createdAtMs = 0,
                    updatedAtMs = 0,
                    sourceMissing = false,
                ),
            ),
        )

        var remoteDownloads = 0
        val loader = LocalFirstLoader(
            local = LocalFirstOriginals(
                reader = AndroidOriginalReader(context),
                loadIndex = { index },
                resolveUri = { mediaType, id -> resolveLocalMediaUri(context, mediaType, id) },
            ),
            remoteThumb = { _, _ -> null },
            remoteDownload = { _, _ -> remoteDownloads++ },
        )

        val asset = AssetMeta(hash = "safHash", mediaType = "video/quicktime", bytes = 12_345L)
        assertEquals(fileDocRaw, loader.localVideoUri(asset, isMine = true))
        assertEquals(0, remoteDownloads)

        // 反证：文档修改后版本不匹配，localVideoUri 必须拒绝直读返回 null。
        every {
            resolver.query(
                fileDocUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )
        } returns cursorRow(1_700_000_999_000L, 12_345L)
        assertNull(loader.localVideoUri(asset, isMine = true))
    }
}
