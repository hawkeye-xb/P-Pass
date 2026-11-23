// #459（MOB-116）：order 的 `source_missing` 由对账轮入口按 MediaStore 差集写——原图删了打 1、同一媒体回来清 0，
// 「已确认且原图还在」（countConfirmedPresent，英雄区 m 的兜底口径）随之下降 / 恢复。
// 边界：部分授权 / 没授权、相册被取消选中、挪到范围外相册、MediaStore 读不出来、用户跳过、已记「源已删」的行——
// 一律不能被误判成 source_missing。真实 FlowEngine + InMemoryOrderStore + FakeMedia。每条附反证。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.folder.CompositeMediaSnapshotSource
import com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG
import com.hawkeyexb.ppass.backup.folder.isFolderId
import com.hawkeyexb.ppass.backup.mediaAbsenceTrusted
import com.hawkeyexb.ppass.backup.order.FakeMedia
import com.hawkeyexb.ppass.backup.order.FakePhoto
import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.SkipTarget
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C459SourceMissingTest {

    /** 两张已确认的照片（bucket 7），G 已过它们：装好之后一直在跑的样子。 */
    private fun TestScope.backedUp(): Rig {
        val rig = Rig(this)
        for (id in 1L..2L) rig.order(rig.photo(id, generation = id), OrderState.CONFIRMED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 2))
        return rig
    }

    private fun Rig.missing(mediaId: Long): Boolean = store.currentForMedia(mediaId)!!.sourceMissing

    // 删了原图 → 对账轮打标记、m 的兜底口径下降，且「最近成功」不因此跳到现在。
    // 反证：去掉 runCycle 里的 reconcileSourcePresence() → 标记恒 0、countConfirmedPresent 仍是 2、兜底 m=2 > n=1，红。
    @Test
    fun `a deleted original is marked by the reconcile round and the confirmed-present count drops`() = runTest {
        val rig = backedUp()
        val lastSuccess = rig.store.lastConfirmedAtMs()
        rig.media.remove(2)
        rig.now = 9_000L
        rig.trigger(TriggerReason.APP_FOREGROUND)

        assertTrue(rig.missing(2))
        assertFalse(rig.missing(1))
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertEquals(1L, rig.store.countConfirmedPresent(setOf(7L)))
        assertEquals("「最近成功」不因删原图而变", lastSuccess, rig.store.lastConfirmedAtMs())
        // 待办还没算出来时英雄区退回 order 表的口径：m 不能比 n 大（#401 的闪现来源之一）。
        val p = FlowProjection.of(rig.store, LoopStatus(), rig.control, setOf(7L), inScopeTotal = 1L, remaining = null)
        assertEquals(1L, p.done)
        assertTrue(rig.logs.any { it.startsWith("source_missing: marked 1 cleared 0") })
        rig.close()
    }

    // 同一个媒体又出现了（例如从回收站恢复，_id 不变）→ 清回 0，计数恢复。
    // 反证：sourcePresencePlan 不收集 clear（只打不清）→ 恢复后仍是 1、计数停在 1，红。
    @Test
    fun `the mark is cleared when the same media comes back`() = runTest {
        val rig = backedUp()
        val photo = rig.media.photos.single { it.mediaId == 2L }
        rig.media.remove(2)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertTrue(rig.missing(2))

        rig.media.put(photo)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.missing(2))
        assertEquals(2L, rig.store.countConfirmedPresent(setOf(7L)))
        rig.close()
    }

    // 部分授权 / 没授权：看不见 ≠ 被删。不打也不清。
    // #1771：门控已从 FlowEngine 全局下沉到 existingIds（MediaStore 侧自己回答「不知道」）——这条用例走的
    // 是「来源回答不知道 → 整步什么都不写」的同一路径。
    // 反证：去掉 reconcileSourcePresence 对 plan == null 的早退（把 null 当空集）→ #2 被打上标记，红。
    @Test
    fun `without full media access absence proves nothing - no mark and no clear`() = runTest {
        val rig = backedUp()
        rig.fullMediaAccess = false
        rig.media.remove(2)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.missing(2))
        assertEquals(2L, rig.store.countConfirmedPresent(setOf(7L)))
        assertTrue(rig.logs.any { it.contains("could not confirm which") })

        // 已有的标记也不清：部分授权下整步不动（看得见的那几张之外什么都不知道）。
        val photo = rig.media.photos.single { it.mediaId == 1L }
        rig.media.remove(1)
        rig.fullMediaAccess = true
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertTrue(rig.missing(1))
        rig.fullMediaAccess = false
        rig.media.put(photo)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertTrue(rig.missing(1))
        rig.close()
    }

    // 判据：完整 = 主相册权限 +（API 33+）视频权限。部分照片（API 34+ 只给 VISUAL_USER_SELECTED）、视频没给 → 不可信。
    // 反证：mediaAbsenceTrusted 只看 imagesGranted → API 33 视频没给那条为 true，红。
    @Test
    fun `absence is trusted only with full image and video access`() {
        assertTrue(mediaAbsenceTrusted(imagesGranted = true, videoGranted = true, sdkInt = 34))
        assertFalse("部分照片授权", mediaAbsenceTrusted(imagesGranted = false, videoGranted = false, sdkInt = 34))
        assertFalse("没授权", mediaAbsenceTrusted(imagesGranted = false, videoGranted = true, sdkInt = 30))
        assertFalse("API 33+ 视频没给：视频全都查不到", mediaAbsenceTrusted(imagesGranted = true, videoGranted = false, sdkInt = 33))
        assertTrue("API < 33 一项存储权限覆盖图片与视频", mediaAbsenceTrusted(imagesGranted = true, videoGranted = false, sdkInt = 32))
    }

    // 相册被取消选中：范围是查询条件，不是删除——即使原图真删了也不在这里判。
    // 反证：sourcePresencePlan 去掉 `!inScope(order.bucketId)` 那条 → 取消选中后 #1、#2 都被打标记，红。
    @Test
    fun `a deselected album is never judged as deleted`() = runTest {
        val rig = backedUp()
        rig.media.scope = setOf(8L)
        rig.media.remove(2)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.missing(1))
        assertFalse(rig.missing(2))
        rig.close()
    }

    // 挪到范围外的相册：范围内列表里没有，但 MediaStore 里还在 → 不是「原图没了」。
    // 反证：把「列表里没有」直接当被删（不经 existingIds 确认）→ #2 被打标记，红。
    @Test
    fun `a photo moved to an out-of-scope album is not marked`() = runTest {
        val rig = backedUp()
        rig.photo(2, generation = 2, bucketId = 8)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.missing(2))
        assertEquals(1, rig.media.existingIdsCalls)
        rig.close()
    }

    // MediaStore 这次读不出来（null 游标）：当「不知道」，一条都不写。
    // 反证：existingIds 返回 null 时当空集 → #2 被打标记，红。
    @Test
    fun `an unreadable MediaStore writes nothing`() = runTest {
        val rig = backedUp()
        rig.media.remove(2)
        rig.media.existingIdsUnreadable = true
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.missing(2))
        assertTrue(rig.logs.any { it.contains("could not confirm which items are gone") })
        rig.close()
    }

    // 用户跳过的、已记「源已删」的行不碰：只看 CONFIRMED，且 #390 横幅的确认水位（按 updated_at）不被搅动。
    // 反证：sourcePresencePlan 不按 CONFIRMED 过滤、setSourceMissing 又改 updated_at → 已确认过的横幅张数回来，红。
    @Test
    fun `skipped and already-settled source-missing rows are left alone`() = runTest {
        val rig = backedUp()
        val skipped = rig.photo(3, generation = 3)
        val gone = rig.photo(4, generation = 4)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 4))
        rig.order(gone, OrderState.SKIPPED_SOURCE_MISSING)
        rig.order(skipped, OrderState.TRANSFERRING)
        rig.store.cancelRemaining(listOf(SkipTarget(3, skipped.snapshot.sourceVersion, 7)))
        assertEquals(OrderState.SKIPPED_BY_USER, rig.state(3))
        rig.control.ack = 5_000L
        rig.now = 9_000L
        val before3 = rig.store.currentForMedia(3)!!
        val before4 = rig.store.currentForMedia(4)!!
        rig.media.remove(3)
        rig.media.remove(4)

        rig.trigger(TriggerReason.APP_FOREGROUND)

        assertEquals(before3, rig.store.currentForMedia(3))
        assertEquals(before4, rig.store.currentForMedia(4))
        assertEquals("已确认过的「源已删」不回到横幅", 0L, rig.store.countSourceMissingSkipped(afterMs = rig.control.ack))
        assertTrue(rig.store.isSkipped(3))
        rig.close()
    }

    // 只有对账轮做这一步：MEDIA_CHANGE（删照片时 MediaWatchJob 发的）不做全量差集。
    // 反证：把 `if (reconcile)` 去掉 → MEDIA_CHANGE 之后就打上了，红。
    @Test
    fun `a plain media change does not run the presence pass`() = runTest {
        val rig = backedUp()
        rig.media.remove(2)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertFalse(rig.missing(2))
        assertEquals(0, rig.media.existingIdsCalls)
        rig.close()
    }

    private fun Rig.unrecoverableAudits() = store.pendingAudit(100).filter { it.payload["disposition"] == "UNRECOVERABLE" }

    // ---------------------------------------------------------------- #1771：缺席可信度按来源判定

    /** #1771：目录来源替身——独立于相册的 [FakeMedia]（缺席可信度可单独切换），ID 用 bit 62 命名空间。 */
    private class FakeFolderSource(private val media: FakeMedia) : MediaSnapshotSource by media

    /** 目录段的一张照片（mediaId / bucketId 都落在 bit 62 命名空间）。 */
    private fun folderPhoto() = FakePhoto(FOLDER_MEDIA_ID, 100L, 4L, "folder", 0L, bucketId = FOLDER_BUCKET)

    // 目录-only：相册权限与目录缺席无关；旧 ID 消失覆盖删除与改名，恢复同一路径后清标。
    // 对齐 iOS c229c7fa 的 testFolderAbsenceIsReconciledWithoutFullPhotoAccess。
    // 反证：恢复 FlowEngine 的全局相册门控，或让 Composite 在纯目录 ID 时仍问 primary（null）→ 第一条断言红。
    @Test
    fun `folder absence is reconciled without full album access`() = runTest {
        val album = FakeMedia()
        val folderMedia = FakeMedia(scope = setOf(FOLDER_BUCKET))
        val composite = CompositeMediaSnapshotSource(album, FakeFolderSource(folderMedia))
        val rig = Rig(
            this,
            mediaOverride = composite,
            primaryMedia = album,
            inScopeOverride = { bucket, _ -> isFolderId(bucket) },
        )
        val item = folderPhoto()
        folderMedia.put(item)
        val order = rig.order(item, OrderState.CONFIRMED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        album.absenceTrusted = false
        val updatedAt = order.updatedAtMs

        folderMedia.remove(FOLDER_MEDIA_ID)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        val marked = rig.store.get(order.id)!!
        assertTrue("目录完整枚举已证实旧 ID 消失，不能被相册权限门控", marked.sourceMissing)
        assertEquals(OrderState.CONFIRMED, marked.state)
        assertEquals("源缺失不改 updated_at", updatedAt, marked.updatedAtMs)
        assertEquals("源缺失不重传、不删除桌面已确认副本", emptyList<Long>(), rig.delivery.requests.map { it.orderId })

        folderMedia.put(item)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse(rig.store.get(order.id)!!.sourceMissing)
        rig.close()
    }

    // 混合来源：相册不可信时不得只写目录的部分结果；两边都可信后才可同时打标。
    // 对齐 iOS c229c7fa 的 testMixedSourcePresenceDoesNotWritePartialFolderResult。
    // 反证：Composite 把 null 来源排除后返回部分并集 → 前两条断言红。
    @Test
    fun `mixed sources never write a partial folder result while the album is untrusted`() = runTest {
        val album = FakeMedia()
        val folderMedia = FakeMedia(scope = setOf(FOLDER_BUCKET))
        val composite = CompositeMediaSnapshotSource(album, FakeFolderSource(folderMedia))
        val rig = Rig(
            this,
            mediaOverride = composite,
            primaryMedia = album,
            inScopeOverride = { bucket, _ -> bucket == 7L || isFolderId(bucket) },
        )
        val item = folderPhoto()
        folderMedia.put(item)
        val photo = rig.photo(2, generation = 2)
        val folderOrder = rig.order(item, OrderState.CONFIRMED)
        val photoOrder = rig.order(photo, OrderState.CONFIRMED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 2))

        folderMedia.remove(FOLDER_MEDIA_ID)
        album.remove(2)
        album.absenceTrusted = false
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertFalse("部分结果不许写：目录侧", rig.store.get(folderOrder.id)!!.sourceMissing)
        assertFalse("部分结果不许写：相册侧", rig.store.get(photoOrder.id)!!.sourceMissing)

        album.absenceTrusted = true
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertTrue(rig.store.get(folderOrder.id)!!.sourceMissing)
        assertTrue(rig.store.get(photoOrder.id)!!.sourceMissing)
        rig.close()
    }

    // 目录缺席不可信 + 桌面也缺：既不标源缺失，也不能记 UNRECOVERABLE 或补传。
    // 对齐 iOS c229c7fa 的 testUnreadableFolderCannotMarkSourceMissingOrUnrecoverable。
    // 反证：把 null 当空集（sourceMissing 断言红），或去掉 Round 的 sourcePresenceTrusted 门控
    //（runRemotePresence 会建新订单 + REUPLOAD 审计，currentForMedia 与审计计数断言红）。
    @Test
    fun `an untrusted folder cannot mark source missing or re-upload a desktop-missing photo`() = runTest {
        val album = FakeMedia()
        val folderMedia = FakeMedia(scope = setOf(FOLDER_BUCKET))
        val composite = CompositeMediaSnapshotSource(album, FakeFolderSource(folderMedia))
        val rig = Rig(
            this,
            mediaOverride = composite,
            primaryMedia = album,
            inScopeOverride = { bucket, _ -> bucket == 7L || isFolderId(bucket) },
        )
        val item = folderPhoto()
        folderMedia.put(item)
        val order = rig.order(item, OrderState.CONFIRMED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        val updatedAt = order.updatedAtMs

        folderMedia.remove(FOLDER_MEDIA_ID)
        folderMedia.absenceTrusted = false
        rig.missingOnDesktop = setOf(item.hash)
        // 一张无关待传：保证这一轮真的进了 loop（否则 Round 的 presence 门控根本没被走到）。
        val unrelated = rig.photo(9, generation = 9)

        rig.trigger(TriggerReason.PERIODIC)
        rig.trigger(TriggerReason.PERIODIC)

        val current = rig.store.get(order.id)!!
        assertFalse(current.sourceMissing)
        assertEquals(OrderState.CONFIRMED, current.state)
        assertEquals(updatedAt, current.updatedAtMs)
        assertEquals("同媒体仍指向原订单，不得新增补传订单", order.id, rig.store.currentForMedia(FOLDER_MEDIA_ID)!!.id)
        assertEquals("只传了那张无关照片，没有被误判的补传", listOf(unrelated.mediaId), rig.delivery.deliveredMediaIds)
        val audits = rig.store.pendingAudit(100)
        assertEquals(0, audits.count { it.payload["disposition"] == "REUPLOAD" })
        assertEquals(0, audits.count { it.payload["disposition"] == "UNRECOVERABLE" })
        rig.close()
    }

    // 桌面缺 + 原图也删了：意图来源 MOB-87 卡面「对账边界」第 6 条（已退役卡片，git 历史 8917fa05 可查；与 #415 裁决 2 一致）——
    // 标 UNRECOVERABLE、只落审计事实、**不提示**：不补传、不建新行、不进「无法恢复」横幅。
    // 反证：去掉 runRemotePresence 按 order.sourceMissing 分流的那一支 → 新建一行、取件记「源已删」、横幅 1 张，红。
    @Test
    fun `a marked photo the desktop lost is audited as unrecoverable and never reaches the banner`() = runTest {
        val rig = backedUp()
        val lost = rig.media.photos.single { it.mediaId == 2L }
        val old = rig.store.currentForMedia(2)!!
        rig.media.remove(2)
        rig.missingOnDesktop = setOf(lost.hash)
        rig.trigger(TriggerReason.PERIODIC)

        assertEquals(1, rig.presenceCalls)
        assertEquals("不补传：当前行还是原来那行 CONFIRMED", old.id, rig.store.currentForMedia(2)!!.id)
        assertTrue(rig.store.get(old.id)!!.sourceMissing)
        assertEquals(0L, rig.store.countSourceMissingSkipped(afterMs = 0L))
        assertEquals(emptyList<Long>(), rig.delivery.requests.map { it.orderId })
        val audits = rig.unrecoverableAudits()
        assertEquals(1, audits.size)
        assertEquals(lost.hash, audits.single().payload["contentHash"])
        rig.close()
    }

    // 同一行、同一配对 id只记一次 UNRECOVERABLE：CONFIRMED 行留着，每个对账轮都会再遇到它。换了配对 id再记一次。
    // 反证：appendAuditOnce 换回 appendAudit → 第二轮又记一条（2 条），红。
    @Test
    fun `the unrecoverable audit is recorded once per order and pairing id`() = runTest {
        val rig = backedUp()
        val lost = rig.media.photos.single { it.mediaId == 2L }
        rig.media.remove(2)
        rig.missingOnDesktop = setOf(lost.hash)
        rig.trigger(TriggerReason.PERIODIC)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(2, rig.presenceCalls)
        assertEquals(1, rig.unrecoverableAudits().size)

        rig.pid = PairingId("e2")
        rig.probeResult = ProbeResult.Reachable()
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(3, rig.presenceCalls)
        assertEquals("新配对 id下再记一次", 2, rig.unrecoverableAudits().size)
        assertEquals(0L, rig.store.countSourceMissingSkipped(afterMs = 0L))
        rig.close()
    }

    /** registry 的分配序：addFolder 先拿 bucketId（FLAG|1），第一个文件项 mediaId = FLAG|2。 */
    private val FOLDER_MEDIA_ID = FOLDER_ID_FLAG or 2L
    private val FOLDER_BUCKET = FOLDER_ID_FLAG or 1L
}
