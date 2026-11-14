// #1762：FolderRegistry 契约。验收场景（issue #1762 E2）：
// 往返 / 重启恢复 / 移除防复用 / 负 Long 映射不撞 MediaStore 正 ID / 路径规范化拒绝绝对路径与 `..`。
// 全部用临时目录里的真实 JSON 文件（同生产持久化路径），不 mock 持久化。
package com.hawkeyexb.ppass.backup.folder

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderRegistryTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun registryFile(): File = File(tmp.root, "folder-registry.json")

    private fun newRegistry(): FolderRegistry = FolderRegistry(registryFile())

    // 往返 + 重启恢复：登记 → 新实例（模拟进程重启）读同一文件 → sourceId / treeUri / bucketId / 状态一致，
    // 且 opaqueId 与 mediaId 的映射稳定（重启后同一相对路径不再分配新 ID）。
    // 反证：reconcile 的分配不落盘（persist 失败仍返回）→ 重启后映射换新 → 已建 order 的 mediaId 失配 → 误标源缺失。
    @Test
    fun `registry round-trips across restarts and keeps id mappings stable`() {
        val first = newRegistry()
        val sourceId = first.addFolder("content://tree/primary%3ADCIM", "DCIM")
        val opaque = first.opaqueId(sourceId, "IMG_1.jpg")
        val mediaId = first.mediaIdOf(sourceId, opaque)!!

        val restarted = newRegistry() // 模拟进程重启：重读同一文件
        val record = restarted.record(sourceId)!!
        assertEquals("DCIM", record.displayName)
        assertEquals("content://tree/primary%3ADCIM", record.treeUri)
        assertEquals(FolderRecord.STATUS_REGISTERED, record.status)
        assertEquals(opaque, restarted.opaqueId(sourceId, "IMG_1.jpg"))
        assertEquals(mediaId, restarted.mediaIdOf(sourceId, opaque))
    }

    // 目录命名空间的 Long ID 置 bit 62：MediaStore 的 `_id` 是小正整数，永不撞上（issue 验收场景）。
    @Test
    fun `allocated ids carry the folder bit and never collide with MediaStore ids`() {
        val registry = newRegistry()
        val sourceId = registry.addFolder("content://tree/x", "x")
        val bucketId = registry.bucketIdOf(sourceId)!!
        val mediaId = registry.mediaIdOf(sourceId, registry.opaqueId(sourceId, "a.jpg"))!!
        assertTrue(isFolderId(bucketId))
        assertTrue(isFolderId(mediaId))
        assertTrue("bucketId 必须是正 Long（负 Long 会被 `_id > 0` 的范围查询漏掉）", bucketId > 0)
        assertTrue(mediaId > 0)
        assertFalse("MediaStore 正 ID 不可能带 bit 62", isFolderId(123L))
        // MediaStore 的 BUCKET_ID 是路径哈希、可为负；负数 bit 62 恒为 1，不许误判成目录命名空间
        //（误判会让负 bucket 相册的照片全部静默漏备份——CodeRabbit 同款意见，反证）。
        assertFalse("负 bucket 不许误判为目录 ID", isFolderId(-1L))
        assertFalse(isFolderId(-4611686018427387905L))
        val fresh = newRegistry()
        assertTrue("分配的 ID 恒非负（bit 62 置位、符号位不占）", fresh.bucketIdOf(fresh.addFolder("content://tree/x", "x"))!! > 0)
    }

    // 移除防复用：removedIds 记账，同一 sourceId 不再解析出 record / 映射；新来源拿全新 UUID（不复用旧 ID）。
    @Test
    fun `a removed source is never reused`() {
        val registry = newRegistry()
        val sourceId = registry.addFolder("content://tree/a", "a")
        registry.opaqueId(sourceId, "x.jpg")
        registry.removeFolder(sourceId)

        assertNull(registry.record(sourceId))
        assertNull(registry.sourceIdOfMedia(registry.mediaIdOf(sourceId, registry.opaqueId(sourceId, "x.jpg")) ?: 0L))
        assertTrue(registry.allRecords().isEmpty())
        val second = registry.addFolder("content://tree/b", "b")
        assertTrue("移除后的 id 不复用", second != sourceId)
    }

    // 路径规范化（FolderPaths）：拒绝绝对路径与 `..`；折叠 `.` 与空段；不折叠 Unicode（判等按字节）。
    @Test
    fun `path normalization rejects absolute paths and dot-dot segments`() {
        assertNull(FolderPaths.normalize("/abs/path"))
        assertNull(FolderPaths.normalize("a/../b"))
        assertNull(FolderPaths.normalize(".."))
        assertEquals("a/b", FolderPaths.normalize("./a/./b"))
        assertEquals("a/b", FolderPaths.normalize("a//b"))
        assertNull("空串不是合法相对路径", FolderPaths.normalize(""))
        assertEquals("相册/Cafe\u00E9.jpg", FolderPaths.normalize("相册/Cafe\u00E9.jpg"))
        // 判等按字节：合成的 U+65 e U+301 与预合成 é 不同，不折叠。
        assertFalse(FolderPaths.same("Cafe\u00E9", "Cafe\u0301"))
    }

    // 完整枚举成功后的 reconcile：新路径分配、缺席项删除并返回缺席 opaqueId（旧 ID 走源缺失流程）。
    @Test
    fun `reconcile allocates new paths and removes absent ones`() {
        val registry = newRegistry()
        val sourceId = registry.addFolder("content://tree/a", "a")
        val first = registry.opaqueId(sourceId, "kept.jpg")
        val goneId = registry.opaqueId(sourceId, "gone.jpg")

        val missing = registry.reconcile(sourceId, listOf("kept.jpg", "new.jpg"))
        assertTrue(missing.contains(goneId))
        assertEquals(first, registry.opaqueId(sourceId, "kept.jpg"))
        assertNull("缺席项的映射已删除", registry.relativePath(sourceId, goneId))
        val newOpaque = registry.opaqueId(sourceId, "new.jpg")
        assertEquals("new.jpg", registry.relativePath(sourceId, newOpaque))
    }

    // 重新授权：换上新树 URI 并恢复 registered；来源已移除 → false（不复用）。
    @Test
    fun `reauthorize updates the tree uri and restores status`() {
        val registry = newRegistry()
        val sourceId = registry.addFolder("content://tree/a", "a")
        registry.markRecoveryUnverified(sourceId)
        assertEquals(FolderRecord.STATUS_RECOVERY_UNVERIFIED, registry.record(sourceId)!!.status)

        assertTrue(registry.reauthorize(sourceId, "content://tree/a2"))
        val record = registry.record(sourceId)!!
        assertEquals("content://tree/a2", record.treeUri)
        assertEquals(FolderRecord.STATUS_REGISTERED, record.status)

        registry.removeFolder(sourceId)
        assertFalse("来源已移除，不许重新授权", registry.reauthorize(sourceId, "content://tree/a3"))
    }

    // 同一目录不许登记成两个来源；bucket 反查随移除失效（inScope 自动退出范围）。
    @Test
    fun `duplicate tree uri is detected and bucket lookup follows removal`() {
        val registry = newRegistry()
        val sourceId = registry.addFolder("content://tree/a", "a")
        val bucketId = registry.bucketIdOf(sourceId)!!
        assertTrue(registry.hasTreeUri("content://tree/a"))
        assertTrue(registry.hasBucket(bucketId))

        registry.removeFolder(sourceId)
        assertFalse(registry.hasTreeUri("content://tree/a"))
        assertFalse("移除后 bucket 反查为 false：范围自动收窄、presence 不再对账", registry.hasBucket(bucketId))
        assertFalse("MediaStore 的相册 bucket 不在目录命名空间", registry.hasBucket(7L))
    }
}
