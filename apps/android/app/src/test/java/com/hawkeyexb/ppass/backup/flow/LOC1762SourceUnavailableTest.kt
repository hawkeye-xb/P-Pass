// #1762：引擎缝。目录来源（素材文件夹）授权失效 → WAITING/sourceUnavailable：
// 不推进 G/S、不写 sourceMissing、不计单张失败、不把在途 order 变成失败或源已删除；
// MediaStore（PhotoKit）行不被误标（presence 对账整体「不知道」）；唤醒计划 = 等用户（AwaitsUser）。
// 走真实组合层 Composite(FakeMedia, FolderMediaSnapshotSource(FileFolderTree))；每条附反证。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.folder.CompositeMediaSnapshotSource
import com.hawkeyexb.ppass.backup.folder.FOLDER_VOLUME
import com.hawkeyexb.ppass.backup.folder.FileFolderTree
import com.hawkeyexb.ppass.backup.folder.FolderMediaSnapshotSource
import com.hawkeyexb.ppass.backup.folder.FolderRegistry
import com.hawkeyexb.ppass.backup.folder.isFolderId
import com.hawkeyexb.ppass.backup.order.FakePhoto
import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.OrderState
import java.io.File
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import com.hawkeyexb.ppass.R
import org.junit.rules.TemporaryFolder

class LOC1762SourceUnavailableTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** folder 段装饰器：可切换撤权（枚举 / lookup / existingIds 抛 SourceUnavailable）。 */
    private class SwitchableFolder(private val wrap: MediaSnapshotSource) : MediaSnapshotSource by wrap {
        var revoked = false
        override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.readInScope(afterId, block)
        }
        override fun lookup(mediaId: Long): MediaDetails? {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.lookup(mediaId)
        }
        override fun existingIds(mediaIds: Collection<Long>): Set<Long>? {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.existingIds(mediaIds)
        }
    }

    /** 装好的引擎：MediaStore 段（bucket 7）× 目录段（真实 FileFolderTree + registry）。 */
    private fun TestScope.rigWithFolder(): Triple<Rig, SwitchableFolder, File> {
        val root = tmp.newFolder("media-root")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        val sourceId = registry.addFolder("file://tree", "media-root")
        File(root, "IMG_9.jpg").writeText("nine")
        val folder = SwitchableFolder(FolderMediaSnapshotSource(registry) { FileFolderTree(root) })
        // primary 段与导入侧共用同一份 FakeMedia（Rig.media）：folder 照片在 FakeMedia 里放一份同 ID 同内容，
        // FakeImporter 才导入得出来（primary 段不会输出它——bucket 不在 scope；folder 段输出 registry 分配的同一 ID）。
        val composite = CompositeMediaSnapshotSource(rigMedia, folder)
        val rig = Rig(
            this,
            mediaOverride = composite,
            inScopeOverride = { bucket, _ -> bucket == 7L || isFolderId(bucket) },
            primaryMedia = rigMedia,
            folderDiscovery = { composite.readFolderInScope() },
        )
        // 先消化 start() 的初始 refreshPending 协程：此刻不脏、未撤权，正常算空。
        // （否则置脏 + 撤权后它才被调度到，异常从 start 的协程逃出——那是既有行为，不是本卡要验的缝。）
        advanceUntilIdle()
        rig.media.put(FakePhoto(FOLDER_MEDIA_ID, 100L, 4L, "nine", 0L, bucketId = FOLDER_BUCKET))
        // 「新相册 / 恢复后」的样子：下一轮走对账扫描（readInScope），folder 的枚举在这里发生。
        rig.store.markScanDirty()
        return Triple(rig, folder, root)
    }

    /** Rig 构造前就要放进照片的 primary 实例（构造参数与 mediaOverride 共用同一实例）。 */
    private val rigMedia = com.hawkeyexb.ppass.backup.order.FakeMedia()


    // 撤权轮（对账扫描）：进 WAITING/sourceUnavailable；MediaStore 已确认行不打 source_missing；
    // G 不推进；没有单张失败。反证：不撤权时同一轮正常收尾（等待清掉、无等待）。
    @Test
    fun `a revoked folder waits as source-unavailable and does not mislabel MediaStore rows`() = runTest {
        val (rig, folder, root) = rigWithFolder()
        // MediaStore 里两张已确认的照片，G 已过它们。
        for (id in 1L..2L) rig.order(rig.photo(id, generation = id), OrderState.CONFIRMED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 2))

        folder.revoked = true
        rig.trigger(TriggerReason.APP_FOREGROUND)

        assertEquals(WaitReason.SOURCE_UNAVAILABLE, rig.control.wait)
        assertEquals(GlobalState.WAITING, rig.engine.view.value.state)
        assertFalse("MediaStore 的已确认行不许被误标", rig.missing(1))
        assertFalse(rig.missing(2))
        assertEquals("G 不推进", 2L, rig.generation())
        assertTrue("没有单张失败记录", rig.store.currentInStates(setOf(OrderState.FAILED)).isEmpty())

        // 反证基准：恢复授权（故障条件去掉）→ 同一轮正常收尾，等待清掉。
        folder.revoked = false
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(null, rig.control.wait)
        rig.close()
    }

    // 来源级 import 失败不是这张照片的失败：order 不进 FAILED、不被标源缺失、引擎进 WAITING。
    // 反证：同位置抛普通异常 = 单张失败（FAILED）——证明来源级真的走另一条路。
    @Test
    fun `an import source-unavailable is not a per-photo failure`() = runTest {
        val (rig, folder, root) = rigWithFolder()
        // 先正常备份一张 folder 照片（拿真实的 mediaId 与 order 行）。
        rig.trigger(TriggerReason.APP_FOREGROUND)
        val row = rig.store.currentForMedia(FOLDER_MEDIA_ID)!!
        assertEquals(OrderState.CONFIRMED, row.state)
        assertEquals(null, rig.control.wait)

        // 中断恢复的样子：行回到待传，folder 撤权 → processExisting 的 lookup 抛 → WAITING。
        assertTrue(rig.store.transition(row.id, setOf(OrderState.CONFIRMED), OrderState.PENDING))
        folder.revoked = true
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(WaitReason.SOURCE_UNAVAILABLE, rig.control.wait)
        assertEquals(OrderState.PENDING, rig.state(FOLDER_MEDIA_ID))
        assertFalse(rig.missing(FOLDER_MEDIA_ID))

        // 恢复授权后 import 抛来源级异常：仍 WAITING、不记这张的失败。
        folder.revoked = false
        rig.importer.failures += SourceUnavailableException("folder permission revoked on import")
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(WaitReason.SOURCE_UNAVAILABLE, rig.control.wait)
        assertEquals(OrderState.PENDING, rig.state(FOLDER_MEDIA_ID))

        // 反证：普通异常在同位置 = 单张失败（FAILED），与来源级不同路。
        rig.importer.failures.clear()
        rig.importer.failures += java.io.IOException("disk hiccup, first attempt")
        rig.importer.failures += java.io.IOException("disk hiccup, retry")
        rig.trigger(TriggerReason.RETRY_FAILED)
        assertEquals(OrderState.FAILED, rig.state(FOLDER_MEDIA_ID))
        assertEquals("普通失败不进 WAITING", null, rig.control.wait)
        rig.close()
    }

    // 唤醒计划：SOURCE_UNAVAILABLE 等用户（不排探测梯），桌面心跳也不叫醒（重新授权才有新触发）。
    @Test
    fun `source-unavailable awaits the user and the heartbeat does not wake it`() = runTest {
        val (rig, folder, root) = rigWithFolder()
        folder.revoked = true
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(WaitReason.SOURCE_UNAVAILABLE, rig.control.wait)
        assertEquals("不排退避探测——恢复只能靠重新授权", 0, rig.scheduler.unreachableProbes)
        rig.engine.onDesktopReachable() // 心跳：桌面可达不构成重新授权
        advanceUntilIdle()
        assertEquals(WaitReason.SOURCE_UNAVAILABLE, rig.control.wait)
        rig.close()
    }

    // 状态行文案 + 唤醒种类映射（穷举 when 的新分支）。
    @Test
    fun `the wait reason maps to the user-facing line and awaits the user`() {
        assertEquals(R.string.state_waiting_source_unavailable, waitReasonTextRes(WaitReason.SOURCE_UNAVAILABLE, null))
        assertTrue(wakePlanOf(WaitReason.SOURCE_UNAVAILABLE) { WakePlan.RetryProbes } is WakePlan.AwaitsUser)
    }

    // 新素材只在 reconcile 轮被发现（ADR §4）：非 reconcile 轮（MEDIA_CHANGE）不枚举目录、不进待办；
    // reconcile 轮（APP_FOREGROUND）枚举 → registry 分配新 ID → 传输。反证：非 reconcile 轮同样在场却不发现。
    @Test
    fun `a reconcile round discovers new folder items without a dirty scan`() = runTest {
        val (rig, folder, root) = rigWithFolder()
        rig.trigger(TriggerReason.APP_FOREGROUND) // 第一轮：扫描脏 → 全量差集 → 原有那张 CONFIRMED
        assertEquals(OrderState.CONFIRMED, rig.state(FOLDER_MEDIA_ID))
        assertEquals("扫描收尾后不再脏", false, rig.store.scanState().dirty)

        // 新素材进目录（真实文件路径写法 = 生产 SAF 枚举对齐的相对路径）；
        // FakeImporter 只认 FakeMedia 的内容，同步放一份同 ID 的（导入侧）。
        java.io.File(root, "new-later.jpg").writeText("added after first backup")
        rig.media.put(FakePhoto(com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 3L, 200L, 23L, "added after first backup", 0L, bucketId = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 1L))

        // 反证：非 reconcile 轮不枚举目录 → 没有待办。
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals("非 reconcile 轮不发现目录新项", 0, rig.pending())
        assertNull(rig.store.currentForMedia(com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 3L))

        // reconcile 轮：目录段全集差集 → 新项进待办并传输。
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(
            "reconcile 轮发现新素材并备份",
            OrderState.CONFIRMED,
            rig.state(com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 3L),
        )
        rig.close()
    }

    private fun Rig.missing(mediaId: Long): Boolean = store.currentForMedia(mediaId)!!.sourceMissing

    /** registry 的分配序：addFolder 先拿 bucketId（FLAG|1），第一个文件项 mediaId = FLAG|2。 */
    private val FOLDER_MEDIA_ID = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 2L
    private val FOLDER_BUCKET = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 1L
}
