// #1762：组合层契约（issue #1762 E2「Composite 在 Folder 撤权时 presence 对账整体返回不知道」）。
// primary 用测试侧 FakeMedia（MediaStore 段），folder 段用真实 FolderMediaSnapshotSource + FileFolderTree。
// 每条附反证。
package com.hawkeyexb.ppass.backup.folder

import com.hawkeyexb.ppass.backup.flow.ImportResult
import com.hawkeyexb.ppass.backup.flow.MediaImporter
import com.hawkeyexb.ppass.backup.flow.ProviderLease
import com.hawkeyexb.ppass.backup.flow.SourceUnavailableException
import com.hawkeyexb.ppass.backup.order.FakeMedia
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.FakePhoto
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CompositeMediaSourceTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private class ImportingFake : MediaImporter {
        val imported = mutableListOf<Long>()
        val released = mutableListOf<String>()
        override fun import(mediaId: Long, contentUri: String, dataPath: String?): ImportResult =
            ImportResult.Imported("hash:$mediaId", 1L, byReference = false).also { imported += mediaId }
        override fun serve(lease: ProviderLease): String = "ticket-${lease.orderId}"
        override fun release(contentHash: String) {
            released += contentHash
        }
    }

    /** folder 段的包装：可切换「撤权」（抛 SourceUnavailable）与正常。 */
    private class SwitchableFolder(private val wrap: FolderMediaSnapshotSource) :
        com.hawkeyexb.ppass.backup.order.MediaSnapshotSource by wrap {
        var revoked = false
        override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.readInScope(afterId, block)
        }
        override fun existingIds(mediaIds: Collection<Long>): Set<Long>? {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.existingIds(mediaIds)
        }
    }

    private fun composite(
        primary: FakeMedia,
        folder: com.hawkeyexb.ppass.backup.order.MediaSnapshotSource,
    ) = CompositeMediaSnapshotSource(primary, folder)

    // 合并：MediaStore 段在前（正 ID）、folder 段在后（bit 62 ID），整体严格升序——对账扫描按序归并依赖。
    @Test
    fun `merged in-scope rows stay strictly ordered by mediaId`() {
        val primary = FakeMedia().also { it.put(FakePhoto(3L, 100L, 10L, "c3", 1L)) }
        val root = tmp.newFolder("media-root")
        File(root, "IMG_9.jpg").writeText("nine")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        val sourceId = registry.addFolder("file://tree", "media-root")
        val folder = FolderMediaSnapshotSource(registry) { FileFolderTree(root) }

        val rows = composite(primary, folder).readInScope(0L) { it.toList() }
        assertEquals(2, rows.size)
        assertEquals(3L, rows[0].mediaId)
        assertTrue(isFolderId(rows[1].mediaId))
    }

    // folder 撤权时 readInScope 抛（整轮等待，不产出半份快照）。
    // 反证：revoked=false 时同一调用正常合并（故障条件在场才红）。
    @Test
    fun `revoked folder fails the whole in-scope read`() {
        val primary = FakeMedia().also { it.put(FakePhoto(3L, 100L, 10L, "c3", 1L)) }
        val root = tmp.newFolder("media-root")
        File(root, "IMG_9.jpg").writeText("nine")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        registry.addFolder("file://tree", "media-root")
        val folder = SwitchableFolder(FolderMediaSnapshotSource(registry) { FileFolderTree(root) })
        val composite = composite(primary, folder)

        composite.readInScope(0L) { assertEquals(2, it.toList().size) } // 反证基准：没撤权时正常

        folder.revoked = true
        try {
            composite.readInScope(0L) { failAssert("撤权后不许产出快照") }
            throw AssertionError("expected SourceUnavailableException")
        } catch (expected: SourceUnavailableException) {
        }
    }

    // presence 对账（issue 验收场景）：folder 撤权 → existingIds **整体** null（不知道），
    // 不许只丢 folder 部分或把 folder 的照片当「全没了」。
    // 反证：没撤权时返回非 null 的并集——证明 null 真的来自撤权。
    @Test
    fun `revoked folder makes existingIds return null for everything`() {
        val primary = FakeMedia().also { it.put(FakePhoto(3L, 100L, 10L, "c3", 1L)) }
        val root = tmp.newFolder("media-root")
        File(root, "IMG_9.jpg").writeText("nine")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        registry.addFolder("file://tree", "media-root")
        val folder = SwitchableFolder(FolderMediaSnapshotSource(registry) { FileFolderTree(root) })
        val composite = composite(primary, folder)

        // 反证基准：folder 正常时 primary 的 ID 回答得出来（非 null）。
        assertEquals(setOf(3L), composite.existingIds(listOf(3L)))

        folder.revoked = true
        assertNull("撤权 → 整体「不知道」，不许部分回答", composite.existingIds(listOf(3L)))
    }

    // lookup 按命名空间分发：folder ID（bit 62）走 folder 段，MediaStore ID 走 primary。
    @Test
    fun `lookup dispatches by id namespace`() {
        val primary = FakeMedia().also { it.put(FakePhoto(3L, 100L, 10L, "c3", 1L)) }
        val root = tmp.newFolder("media-root")
        File(root, "IMG_9.jpg").writeText("nine")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        val sourceId = registry.addFolder("file://tree", "media-root")
        val composite = composite(primary, FolderMediaSnapshotSource(registry) { FileFolderTree(root) })

        assertEquals(3L, composite.lookup(3L)!!.snapshot.mediaId)
        val folderMediaId = composite.readInScope(0L) { it.toList() }.last().mediaId
        assertTrue(isFolderId(folderMediaId))
        assertEquals(sourceId, registry.sourceIdOfMedia(folderMediaId))
        assertEquals("IMG_9.jpg", composite.lookup(folderMediaId)!!.fileName)
        assertNull(composite.lookup(999L))
    }

    // G 游标口径（ADR §4）：readChangedSince / maxGeneration / volumeNames 全部只反映 MediaStore 段，
    // 目录新项只在 reconcile（readInScope）轮出现。
    @Test
    fun `changed-since and volume queries only reflect the MediaStore side`() {
        val primary = FakeMedia().also { it.put(FakePhoto(3L, 100L, 10L, "c3", 5L)) }
        val root = tmp.newFolder("media-root")
        File(root, "IMG_9.jpg").writeText("nine")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        registry.addFolder("file://tree", "media-root")
        val composite = composite(primary, FolderMediaSnapshotSource(registry) { FileFolderTree(root) })

        val changed = composite.readChangedSince(LEGACY_VOLUME, 0L, 0L) { it.toList() }
        assertEquals(listOf(3L), changed.map { it.mediaId })
        assertEquals(5L, composite.maxGeneration(LEGACY_VOLUME))
        assertEquals(listOf(LEGACY_VOLUME), composite.volumeNames())
    }

    // CompositeMediaImporter：folder 文档 URI 的授权失效（SecurityException）→ SourceUnavailableException（来源级）；
    // 非 folder ID 的 SecurityException 原样抛（相册权限问题不冒充目录问题）；release 委托。
    @Test
    fun `importer turns folder security failures into source-unavailable`() {
        val importer = CompositeMediaImporter(ThrowingImporter())
        try {
            importer.import(FOLDER_ID_FLAG or 1L, "content://doc", null)
            throw AssertionError("expected SourceUnavailableException")
        } catch (expected: SourceUnavailableException) {
        }
        try {
            importer.import(3L, "content://media/3", null)
            throw AssertionError("expected SecurityException")
        } catch (expected: SecurityException) {
        }
    }

    private class ThrowingImporter : MediaImporter {
        override fun import(mediaId: Long, contentUri: String, dataPath: String?): ImportResult =
            throw SecurityException("permission revoked")
        override fun serve(lease: ProviderLease): String = "ticket"
        override fun release(contentHash: String) = Unit
    }

    private fun failAssert(message: String) {
        throw AssertionError(message)
    }
}
