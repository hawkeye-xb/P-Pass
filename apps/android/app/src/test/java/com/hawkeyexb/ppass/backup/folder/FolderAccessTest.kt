package com.hawkeyexb.ppass.backup.folder

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.hawkeyexb.ppass.log.PLog
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.runs
import io.mockk.unmockkStatic
import io.mockk.verify
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderAccessTest {

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

    private fun mockTreeUri(raw: String, docId: String): Uri {
        val uri = mockk<Uri>(relaxed = true)
        every { uri.toString() } returns raw
        every { uri.lastPathSegment } returns docId
        every { Uri.parse(raw) } returns uri
        every { DocumentsContract.getTreeDocumentId(uri) } returns docId
        return uri
    }

    @Before
    fun setUp() {
        resetFolderAccessSingleton()
        PLog.sink = PLog.Sink { _, _, _ -> }
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
        PLog.resetSink()
        resetFolderAccessSingleton()
    }

    @Test
    fun `reauthorize allows matching relative path when volume id changes and handles root boundaries`() {
        val oldRaw = "content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera"
        val newRaw = "content://com.android.externalstorage.documents/tree/1234-5678%3ADCIM%2FCamera"
        val oldUri = mockTreeUri(oldRaw, "primary:DCIM/Camera")
        val newUri = mockTreeUri(newRaw, "1234-5678:DCIM/Camera")

        val sourceId = FolderAccess.registry(context).addFolder(oldRaw, "Camera")
        assertTrue(
            "去掉卷 ID 后相对路径同为 DCIM/Camera 时应允许平滑重授",
            FolderAccess.reauthorize(context, sourceId, newUri),
        )
        assertEquals(newRaw, FolderAccess.registry(context).record(sourceId)?.treeUri)
        verify { resolver.takePersistableUriPermission(newUri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        verify { resolver.releasePersistableUriPermission(oldUri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }

        // 根路径边界：同为卷根（如拔插外置卷后卷标变化）同样应平滑重授，且相对路径不一致时仍拒绝。
        val rootOldRaw = "content://com.android.externalstorage.documents/tree/AAAA-1111%3A"
        val rootNewRaw = "content://com.android.externalstorage.documents/tree/BBBB-2222%3A%2F"
        mockTreeUri(rootOldRaw, "AAAA-1111:")
        val rootNewUri = mockTreeUri(rootNewRaw, "BBBB-2222:/")
        val rootId = FolderAccess.registry(context).addFolder(rootOldRaw, "SD Card")
        assertTrue(
            "同为卷根（去卷 ID 后相对段均为根）应允许平滑重授",
            FolderAccess.reauthorize(context, rootId, rootNewUri),
        )
    }

    @Test
    fun `reauthorize rejects mismatched relative directory path and keeps old uri`() {
        val oldRaw = "content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera"
        val wrongRaw = "content://com.android.externalstorage.documents/tree/1234-5678%3ADCIM%2FScreenshots"
        mockTreeUri(oldRaw, "primary:DCIM/Camera")
        val wrongUri = mockTreeUri(wrongRaw, "1234-5678:DCIM/Screenshots")

        val sourceId = FolderAccess.registry(context).addFolder(oldRaw, "Camera")
        assertFalse(
            "相对目录路径不一致时必须拒绝重授，防止误选其他目录",
            FolderAccess.reauthorize(context, sourceId, wrongUri),
        )
        assertEquals(oldRaw, FolderAccess.registry(context).record(sourceId)?.treeUri)
        verify(exactly = 0) { resolver.takePersistableUriPermission(wrongUri, any()) }
    }

    @Test
    fun `takePersistable SecurityException returns false or null without crashing`() {
        val oldRaw = "content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera"
        val addRaw = "content://com.android.externalstorage.documents/tree/primary%3APictures"
        val oldUri = mockTreeUri(oldRaw, "primary:DCIM/Camera")
        val addUri = mockTreeUri(addRaw, "primary:Pictures")

        val sourceId = FolderAccess.registry(context).addFolder(oldRaw, "Camera")
        every { resolver.takePersistableUriPermission(any(), any()) } throws SecurityException("persist denied")

        val reauthOk = FolderAccess.reauthorize(context, sourceId, oldUri)
        assertFalse("持久授权被系统拒绝时 reauthorize 必须返回 false 而不闪退", reauthOk)

        val addedId = FolderAccess.addFolder(context, addUri)
        assertNull("持久授权被系统拒绝时 addFolder 必须返回 null 而不闪退", addedId)
        assertNull(FolderAccess.registry(context).allRecords().firstOrNull { it.treeUri == addRaw })

        every { resolver.takePersistableUriPermission(addUri, any()) } just runs
        assertNotNull("恢复正常授权后仍可正常添加", FolderAccess.addFolder(context, addUri))
    }

    @Test
    fun `sameTreeDirectory handles volume changes, slashes, roots, and rejects invalid or mismatched paths`() {
        assertTrue(FolderAccess.sameTreeDirectory("primary:DCIM/Camera", "primary:DCIM/Camera"))
        assertTrue(FolderAccess.sameTreeDirectory("primary:DCIM/Camera", "9999-8888:DCIM/Camera"))
        assertTrue(FolderAccess.sameTreeDirectory("primary:/DCIM/./Camera/", "vol2:DCIM/Camera"))
        assertTrue(FolderAccess.sameTreeDirectory("AAAA-1111:", "AAAA-1111:"))
        assertTrue(FolderAccess.sameTreeDirectory("AAAA-1111:", "BBBB-2222:/"))
        assertFalse(FolderAccess.sameTreeDirectory("AAAA-1111:", "AAAA-1111:DCIM"))
        assertFalse(FolderAccess.sameTreeDirectory("primary:DCIM/Camera", "primary:DCIM"))
        assertFalse(FolderAccess.sameTreeDirectory(":DCIM/Camera", "primary:DCIM/Camera"))
        assertFalse(FolderAccess.sameTreeDirectory("opaque-1", "opaque-2"))
        assertTrue(FolderAccess.sameTreeDirectory("opaque-1", "opaque-1"))
        assertFalse(FolderAccess.sameTreeDirectory("primary:a/../b", "other:b"))
        assertFalse(FolderAccess.sameTreeDirectory("", "primary:DCIM"))
    }

    @Test
    fun `areAllReadable returns true only when every registered folder passes checkReadable`() {
        val okRaw = "content://com.android.externalstorage.documents/tree/primary%3ADCIM"
        val badRaw = "content://com.android.externalstorage.documents/tree/primary%3ADownload"
        val okUri = mockTreeUri(okRaw, "primary:DCIM")
        val badUri = mockTreeUri(badRaw, "primary:Download")
        val okChildren = mockk<Uri>()
        val badChildren = mockk<Uri>()
        every { DocumentsContract.buildChildDocumentsUriUsingTree(okUri, "primary:DCIM") } returns okChildren
        every { DocumentsContract.buildChildDocumentsUriUsingTree(badUri, "primary:Download") } returns badChildren

        FolderAccess.registry(context).addFolder(okRaw, "DCIM")
        FolderAccess.registry(context).addFolder(badRaw, "Download")

        val okCursor = mockk<android.database.Cursor>(relaxed = true)
        every { okCursor.moveToFirst() } returns true
        every { resolver.query(okChildren, any(), any(), any(), any()) } returns okCursor
        every { resolver.query(badChildren, any(), any(), any(), any()) } throws SecurityException("revoked")

        assertFalse("任一目录不可读时 areAllReadable 必须返回 false", FolderAccess.areAllReadable(context))

        val okCursor2 = mockk<android.database.Cursor>(relaxed = true)
        every { okCursor2.moveToFirst() } returns true
        every { resolver.query(badChildren, any(), any(), any(), any()) } returns okCursor2
        assertTrue("全部目录恢复可读时 areAllReadable 必须返回 true", FolderAccess.areAllReadable(context))
    }

    @Test
    fun `reauthorize rejects uri already registered by another source without touching persistable permissions`() {
        val rawA = "content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera"
        val rawB = "content://com.android.externalstorage.documents/tree/1234-5678%3ADCIM%2FCamera"
        val rawNew = "content://com.android.externalstorage.documents/tree/9999-8888%3ADCIM%2FCamera"
        val uriA = mockTreeUri(rawA, "primary:DCIM/Camera")
        val uriB = mockTreeUri(rawB, "1234-5678:DCIM/Camera")
        val uriNew = mockTreeUri(rawNew, "9999-8888:DCIM/Camera")

        val registry = FolderAccess.registry(context)
        val sourceA = registry.addFolder(rawA, "Camera A")
        val sourceB = registry.addFolder(rawB, "Camera B")

        assertFalse(
            "目标 URI 已被另一来源占用时必须直接拒绝，防止后续移除误释放对方授权",
            FolderAccess.reauthorize(context, sourceA, uriB),
        )
        assertEquals(rawA, registry.record(sourceA)?.treeUri)
        assertEquals(rawB, registry.record(sourceB)?.treeUri)
        verify(exactly = 0) { resolver.takePersistableUriPermission(uriB, any()) }
        verify(exactly = 0) { resolver.releasePersistableUriPermission(uriB, any()) }
        verify(exactly = 0) { resolver.releasePersistableUriPermission(uriA, any()) }

        assertTrue(
            "同一 sourceId 使用原 URI 重授仍应放行",
            FolderAccess.reauthorize(context, sourceA, uriA),
        )
        assertTrue(
            "同一 sourceId 使用未登记的新卷 URI 重授仍应放行",
            FolderAccess.reauthorize(context, sourceA, uriNew),
        )
        assertEquals(rawNew, registry.record(sourceA)?.treeUri)
        assertEquals(rawB, registry.record(sourceB)?.treeUri)
    }
}
