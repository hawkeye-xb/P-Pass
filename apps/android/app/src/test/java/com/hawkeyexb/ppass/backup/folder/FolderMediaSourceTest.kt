// #1762：FolderMediaSnapshotSource + FileFolderTree 契约（issue #1762 E2）：
// 递归枚举、类型过滤（只照片/视频）、sourceVersion 口径、授权失效抛 SourceUnavailable、
// 完整枚举成功后的 reconcile（缺席 = 源缺失）、lookup 的文件缺失/授权失效两分。
// JVM 走 java.io.File 实现；SAF 实现的可信依赖（DocumentFile 查询、权限撤销）在 E3 真机核。
package com.hawkeyexb.ppass.backup.folder

import com.hawkeyexb.ppass.backup.flow.SourceUnavailableException
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderMediaSourceTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun registry(): FolderRegistry = FolderRegistry(File(tmp.root, "registry.json"))

    /** 根目录 + registry + 来源，返回三件套。素材直接写在 root 里。 */
    private fun setup(): Triple<File, FolderRegistry, String> {
        val root = tmp.newFolder("media-root")
        val registry = registry()
        val sourceId = registry.addFolder("file://tree", "media-root")
        return Triple(root, registry, sourceId)
    }

    private fun source(registry: FolderRegistry, sourceId: String, root: File): FolderMediaSnapshotSource =
        FolderMediaSnapshotSource(registry) { FileFolderTree(root) }

    private fun write(root: File, relative: String, bytes: String): File {
        val file = File(root, relative)
        file.parentFile.mkdirs()
        file.writeText(bytes)
        return file
    }

    // 递归枚举：嵌套子目录里的照片/视频都进快照；按 mediaId 升序（对账扫描按序归并依赖）。
    @Test
    fun `enumeration is recursive and snapshots are ordered by mediaId`() {
        val (root, registry, sourceId) = setup()
        write(root, "IMG_1.jpg", "one")
        write(root, "nested/VID_2.mp4", "two")
        write(root, "nested/deeper/IMG_3.png", "three")
        val src = source(registry, sourceId, root)

        val snapshots = src.readInScope(0L) { it.toList() }
        assertEquals(3, snapshots.size)
        assertEquals(snapshots.sortedBy { it.mediaId }, snapshots)
        for (snap in snapshots) {
            val path = registry.relativePath(sourceId, registry.opaqueIdOfMedia(snap.mediaId)!!)
            assertTrue(path in setOf("IMG_1.jpg", "nested/VID_2.mp4", "nested/deeper/IMG_3.png"))
        }
        // 快照的 bucket 就是来源分配的 bucket；volume 是占位，不进卷口径。
        assertTrue(snapshots.all { it.bucketId == registry.bucketIdOf(sourceId) })
        assertTrue(snapshots.all { it.volumeName == FOLDER_VOLUME })
    }

    // 类型过滤（issue 验收场景）：只照片/视频；.txt / .pdf 等忽略、不计失败。
    // 反证：把过滤去掉（isMediaMime 恒真）→ txt 也进快照 → 会被当成照片备份，红。
    @Test
    fun `only photos and videos are enumerated`() {
        val (root, registry, sourceId) = setup()
        write(root, "IMG_1.jpg", "photo")
        write(root, "notes.txt", "text")
        write(root, "clip.mp4", "video")
        val src = source(registry, sourceId, root)

        val paths = src.readInScope(0L) { rows ->
            rows.map { registry.relativePath(sourceId, registry.opaqueIdOfMedia(it.mediaId)!!) }.toList()
        }
        assertEquals(setOf("IMG_1.jpg", "clip.mp4"), paths.toSet())
        assertTrue("isMediaMime 是过滤的本体", !isMediaMime("text/plain") && isMediaMime("image/jpeg") && isMediaMime("video/mp4"))
    }

    // sourceVersion 口径 = mtime(秒):size，与 MediaStore 的 sourceVersionOf 同一函数。
    @Test
    fun `sourceVersion uses the same modifiedAt-colon-size shape as MediaStore`() {
        val (root, registry, sourceId) = setup()
        val file = write(root, "IMG_1.jpg", "photo bytes")
        val src = source(registry, sourceId, root)

        val snapshot = src.readInScope(0L) { it.toList() }.single()
        val expected = "${file.lastModified() / 1000}:${file.length()}"
        assertEquals(expected, snapshot.sourceVersion)
    }

    // 授权失效 = 根不可达：enumerate 抛 SourceUnavailableException，readInScope 原样抛（整轮等待，不报空集）。
    // 反证：目录在场时同一调用不抛（去掉故障条件必须变绿），说明异常真的来自根不可达。
    @Test
    fun `unreachable root raises SourceUnavailable and not an empty list`() {
        val (root, registry, sourceId) = setup()
        write(root, "IMG_1.jpg", "photo")
        val src = source(registry, sourceId, root)

        src.readInScope(0L) { assertTrue(it.toList().size == 1) } // 故障条件不在场：不抛

        root.deleteRecursively() // 撤销授权的可测等价：根目录没了
        try {
            src.readInScope(0L) { fail("不许把「不可用」当成空列表") }
            throw AssertionError("expected SourceUnavailableException")
        } catch (expected: SourceUnavailableException) {
            // 来源级不可用：调用方（FlowEngine）据此进 WAITING/sourceUnavailable。
        }
        // registry 没被清：恢复授权后映射与已建 order 仍对得上。
        assertTrue(registry.allRecords().isNotEmpty())
    }

    // 完整枚举成功后的 reconcile：新文件出现在下一轮；删除的文件从映射里消失（旧 ID 走源缺失）。
    // 反证：缺席项不从映射删除 → readInScope 永远列它 → lookup null → 每轮空转打转，红。
    @Test
    fun `full enumeration reconciles additions and removals`() {
        val (root, registry, sourceId) = setup()
        write(root, "IMG_1.jpg", "one")
        write(root, "IMG_2.jpg", "two")
        val src = source(registry, sourceId, root)

        val first = src.readInScope(0L) { it.toList() }
        assertEquals(2, first.size)
        val gone = registry.opaqueIdOfMedia(first[0].mediaId)!!
        File(root, "IMG_1.jpg").delete()

        val second = src.readInScope(0L) { it.toList() }
        assertEquals(1, second.size)
        assertNull("已删文件的映射删除，不再进快照", registry.relativePath(sourceId, gone))
        assertTrue("缺席项由 reconcile 返回（调用方经 existingIds 记源缺失）",
            registry.reconcile(sourceId, listOf("IMG_2.jpg")).isEmpty())
    }

    // lookup：文件在场 → details（uri 非空、dataPath=null）；文件没了 → null（源缺失）；
    // 根不可达 → SourceUnavailableException（不许混成 null）。
    @Test
    fun `lookup distinguishes missing file from unavailable source`() {
        val (root, registry, sourceId) = setup()
        write(root, "IMG_1.jpg", "photo")
        val src = source(registry, sourceId, root)
        val mediaId = src.readInScope(0L) { it.toList() }.single().mediaId

        val details = src.lookup(mediaId)
        assertNotNull(details)
        assertEquals("IMG_1.jpg", details!!.fileName)
        assertEquals("image/jpeg", details.mimeType)
        assertTrue(details.uri.isNotEmpty())
        assertNull("SAF 没有真实路径：导入走复制（picked 先例同口径）", details.dataPath)

        File(root, "IMG_1.jpg").delete()
        assertNull("文件没了 = 源缺失（单张），不是来源不可用", src.lookup(mediaId))

        root.deleteRecursively()
        try {
            src.lookup(mediaId)
            throw AssertionError("expected SourceUnavailableException")
        } catch (expected: SourceUnavailableException) {
        }
        assertNull("目录外的 ID 不归 folder 源", src.lookup(123L))
        assertNull("非目录 ID 不归 folder 源", src.lookup(123L))
    }

    // stat：单文件元数据（O(路径深度)），文件不在 → null。
    @Test
    fun `stat reads one file without walking the tree`() {
        val (root, registry, _) = setup()
        val file = write(root, "nested/IMG_1.jpg", "photo")
        val tree = FileFolderTree(root)

        val meta = tree.stat("nested/IMG_1.jpg")
        assertEquals(file.length(), meta!!.sizeBytes)
        assertEquals("image/jpeg", meta.mimeType)
        assertEquals("nested/IMG_1.jpg", meta.relativePath)
        assertNull(tree.stat("nested/gone.jpg"))
    }

    // existingIds：最近一次完整枚举后，缺席 = 不在；来源授权失效 → 抛（Composite 整体转「不知道」）。
    @Test
    fun `existingIds answers from the last trusted scan and raises when unavailable`() {
        val (root, registry, sourceId) = setup()
        write(root, "IMG_1.jpg", "one")
        val src = source(registry, sourceId, root)
        val mediaId = src.readInScope(0L) { it.toList() }.single().mediaId

        assertEquals(setOf(mediaId), src.existingIds(listOf(mediaId)))
        assertTrue("非目录 ID 不归 folder 源", src.existingIds(listOf(7L))!!.isEmpty())

        File(root, "IMG_1.jpg").delete()
        src.readInScope(0L) { it.toList() } // 下一轮完整枚举：reconcile 把缺席项从映射删除
        assertTrue("缺席 → 不在（order 行经 mark 流程记源缺失）", src.existingIds(listOf(mediaId))!!.isEmpty())

        // 撤权（根不可达）：涉及现存 item 的查询必须抛（不许当「全不在」）。
        // 反证基准在上面：授权在场时回答非 null。
        write(root, "IMG_1.jpg", "one again") // 让 items 非空（重新分配，拿当前映射的 ID）
        val currentId = src.readInScope(0L) { it.toList() }.single().mediaId
        root.deleteRecursively()
        try {
            src.existingIds(listOf(currentId))
            throw AssertionError("expected SourceUnavailableException")
        } catch (expected: SourceUnavailableException) {
        }
    }

    private fun fail(message: String) {
        throw AssertionError(message)
    }
}
