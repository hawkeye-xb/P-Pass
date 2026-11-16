package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.folder.CompositeMediaSnapshotSource
import com.hawkeyexb.ppass.backup.folder.FileFolderTree
import com.hawkeyexb.ppass.backup.folder.FolderMediaSnapshotSource
import com.hawkeyexb.ppass.backup.folder.FolderRegistry
import com.hawkeyexb.ppass.backup.order.FakePhoto
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.ScopeTimeOf
import com.hawkeyexb.ppass.proto.FLOW_SUPERSEDE_CAPABILITY
import java.io.File
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * #1263：范围 = 相册 + 开始时间。时间条件只是 inScope 里多一个 `DATE_ADDED >= since`，
 * 扩大 / 缩小沿用 #413 裁定 8：已传完的不删；在途被移出的不续传、丢半截；没传的从待办消失，扩回来自动回来。
 */
class C1263ScopeTimeTest {
    private val today = 1_000L

    // 「从今天起」：以前的照片不传，今天之后新增的照片会传。
    // 反证：readChangedSince / inScope 不看 since → #1 也被传，红。
    @Test
    fun `since today skips earlier photos and sends today's`() = runTest {
        val rig = Rig(this)
        rig.media.since = today
        rig.photo(1, generation = 1, dateAdded = today - 1)
        rig.photo(2, generation = 2, dateAdded = today)
        rig.trigger()
        assertEquals(listOf(2L), rig.delivery.deliveredMediaIds)
        assertEquals(0, rig.pending())
        rig.photo(3, generation = 3, dateAdded = today + 60)
        rig.trigger()
        assertEquals(listOf(2L, 3L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // 改成「全部」= 范围扩大：走补扫（SCOPE_ADDED），以前的照片补传上来。
    // 顺序按现有引擎走（10-29 定稿，不改引擎）：#413 取件优先级里对账扫描先于新照片（case matrix D-01），
    // 先补以前的照片 #1 #2，补扫期间新拍的 #3 排在后面。
    // 反证：SCOPE_ADDED 不置脏 / readInScope 仍按 since 过滤 → #1 #2 取不到，红。
    @Test
    fun `widening to all backfills earlier photos after new ones`() = runTest {
        // 生产的起点：onboarding 第一轮 G 从当前最大 generation 起步，已有的照片只能由对账扫描取到。
        val rig = Rig(this, cursors = false)
        rig.media.since = today
        rig.photo(1, generation = 1, dateAdded = today - 86_400)
        rig.photo(2, generation = 2, dateAdded = today - 3_600)
        rig.trigger()
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)

        rig.media.since = null
        rig.photo(3, generation = 3, dateAdded = today + 10) // 补扫开始前刚拍的
        rig.trigger(TriggerReason.SCOPE_ADDED)
        assertEquals(listOf(1L, 2L, 3L), rig.delivery.deliveredMediaIds)
        assertEquals(0, rig.pending())
        rig.close()
    }

    // 改回「从今天起」= 范围缩小：没传的不再传（从待办消失），在途的丢半截，已传完的不删；扩回来自动回来。
    // 反证：hasWork / 取件按相册不按时间 → 老照片 #1 照传，红；processExisting 不看时间 → #2 被续传，红。
    @Test
    fun `narrowing back to since today drops pending, discards in-flight, keeps confirmed`() = runTest {
        val rig = Rig(this)
        val old1 = rig.photo(1, generation = 1, dateAdded = today - 100)
        val old2 = rig.photo(2, generation = 2, dateAdded = today - 50)
        val old3 = rig.photo(3, generation = 3, dateAdded = today - 10)
        rig.order(old1, OrderState.PENDING)
        val inFlight = rig.order(old2, OrderState.TRANSFERRING)
        rig.order(old3, OrderState.CONFIRMED)
        rig.store.advanceGeneration(com.hawkeyexb.ppass.backup.order.GenerationAdvance(com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME, 3))

        rig.media.since = today
        rig.trigger()
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)
        assertEquals(listOf(inFlight.id), rig.delivery.discarded)
        assertEquals(OrderState.PENDING, rig.state(2))
        assertEquals(OrderState.CONFIRMED, rig.state(3))
        assertEquals(0, rig.pending())
        // 范围外的待传输不让每次触发空转 FGS。
        val acquires = rig.foreground.acquires
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(acquires, rig.foreground.acquires)
        // 账目按范围数：范围外的已确认不进「已备份」。
        assertEquals(0L, rig.store.countConfirmedPresent(setOf(7L), today))
        assertEquals(1L, rig.store.countConfirmedPresent(setOf(7L), null))

        rig.media.since = null
        rig.trigger(TriggerReason.SCOPE_ADDED)
        assertTrue(rig.delivery.deliveredMediaIds.containsAll(listOf(1L, 2L)))
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertEquals(0, rig.pending())
        rig.close()
    }

    // ---------------------------------------------------------------- 旧订单查询侧重算（#1778 / 评审 4583725659）
    //
    // 升级前写入的行，date_added_sec 是旧口径（DATE_ADDED，入 MediaStore 的时刻），schema 不变、不迁移；
    // 引擎的门槛 / 取件 / 对账一律按当前来源的拍摄时间重算（生产 = AndroidFlowRuntime.scopeTimeOf，测试 = rig 的
    // inScope 走同一条 media.lookup），stored 只作 lookup 失败时的回退。

    /** 升级前的旧行：state、hash、locationRedacted 可指定，dateAddedSec 用旧口径的存储值。 */
    private fun oldRow(
        rig: Rig,
        mediaId: Long,
        version: String,
        bucketId: Long,
        storedDateAddedSec: Long,
        state: OrderState = OrderState.PENDING,
        hash: String? = null,
        locationRedacted: Boolean = false,
    ) = rig.store.insert(
        NewOrder(mediaId, version, bucketId, hash, state, "e1", locationRedacted, dateAddedSec = storedDateAddedSec),
    )

    /** 与生产同型的重算：按当前来源查拍摄时间，查不到退回 stored。 */
    private fun recalcOf(rig: Rig): ScopeTimeOf = { mediaId, stored ->
        rig.media.lookup(mediaId)?.snapshot?.dateAddedSec ?: stored
    }

    // 反证：门槛 / 取件只用 stored（旧口径）→ 老照片被当成「今天起」的新内容传上去，红。
    @Test
    fun `old pending orders retry by the recalculated capture time, not the stored date`() = runTest {
        val rig = Rig(this)
        val old = rig.photo(1, generation = 1, dateAdded = today - 86_400) // 昨天拍的
        oldRow(rig, 1, old.snapshot.sourceVersion, 7, storedDateAddedSec = today) // 旧行：DATE_ADDED = 今天
        rig.photo(2, generation = 2, dateAdded = today) // 今天的新照片（新行写入即拍摄时间）
        rig.media.since = today
        rig.trigger()
        assertEquals("旧行按拍摄时间在范围外：不补传", listOf(2L), rig.delivery.deliveredMediaIds)
        assertEquals("范围外的旧 PENDING 原样留着", OrderState.PENDING, rig.state(1))
        // 范围外的旧待传输不让每次触发空转前台服务。
        val acquires = rig.foreground.acquires
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(acquires, rig.foreground.acquires)
        rig.close()
    }

    // 反方向：stored（旧口径）在范围外、拍摄时间在范围内——重算后照常重试，不因旧行漏掉这张。
    @Test
    fun `an old row whose capture time is inside the scope is still retried`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1, dateAdded = today)
        oldRow(rig, 1, p.snapshot.sourceVersion, 7, storedDateAddedSec = today - 86_400)
        rig.media.since = today - 43_200
        rig.trigger()
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // 对账轮的 FAILED 门控与重试按重算：范围外的旧失败行不起前台服务、不计失败；范围内的照常重试。
    @Test
    fun `old failed orders gate and retry on the recalculated time`() = runTest {
        val rig = Rig(this)
        val f = rig.photo(1, generation = 1, dateAdded = today - 86_400)
        oldRow(rig, 1, f.snapshot.sourceVersion, 7, storedDateAddedSec = today, state = OrderState.FAILED)
        rig.media.since = today
        rig.trigger(TriggerReason.APP_FOREGROUND) // 只有对账轮看 FAILED
        assertEquals("范围外的旧 FAILED：不重试", emptyList<Long>(), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.FAILED, rig.state(1))
        assertEquals("不起前台服务", 0, rig.foreground.acquires)
        rig.close()

        val rig2 = Rig(this)
        val p = rig2.photo(1, generation = 1, dateAdded = today)
        oldRow(rig2, 1, p.snapshot.sourceVersion, 7, storedDateAddedSec = today - 86_400, state = OrderState.FAILED)
        rig2.media.since = today - 43_200
        rig2.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals("范围内的旧 FAILED 照常重试", listOf(1L), rig2.delivery.deliveredMediaIds)
        rig2.close()
    }

    // 旧 CONFIRMED：不进「用原图替换旧副本」，也不进「已备份」账目；账目按重算、不按 stored。
    // 反证：升级路径 / 计数仍看 stored → 原地替换被触发、账目 +1，红。
    @Test
    fun `old confirmed rows are not upgraded and count by the recalculated time`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1, dateAdded = today - 86_400)
        oldRow(rig, 1, p.snapshot.sourceVersion, 7, storedDateAddedSec = today, OrderState.CONFIRMED, hash = p.hash, locationRedacted = true)
        rig.importer.hashOverride[1L] = "blake3:original-with-gps"
        rig.locationReadable = true
        rig.probeResult = ProbeResult.Reachable(capabilities = setOf(FLOW_SUPERSEDE_CAPABILITY))
        rig.media.since = today
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals("范围外的旧 CONFIRMED：不原地替换", emptyList<Triple<String, String, String>>(), rig.supersedeCalls)
        assertEquals("不起前台服务", 0, rig.foreground.acquires)
        assertEquals("账目按重算：不进「已备份」", 0L, rig.store.countConfirmedPresent(setOf(7L), today, recalcOf(rig)))
        assertEquals("旧口径（不重算）才把它算进来", 1L, rig.store.countConfirmedPresent(setOf(7L), today))
        rig.close()
    }

    // 首页投影：confirmed（与「已跳过」）按重算；不传 scopeTimeOf 的旧口径仍是反证基准。
    @Test
    fun `home projection counts by the recalculated time`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1, dateAdded = today - 86_400)
        oldRow(rig, 1, p.snapshot.sourceVersion, 7, storedDateAddedSec = today, OrderState.CONFIRMED, hash = p.hash)
        val facts = FlowProjection.facts(rig.store, rig.control, setOf(7L), null, view = null, sinceSec = today, scopeTimeOf = recalcOf(rig))
        assertEquals("范围外的旧已确认不进「已备份」", 0L, facts.confirmed)
        val legacy = FlowProjection.facts(rig.store, rig.control, setOf(7L), null, view = null, sinceSec = today)
        assertEquals("旧口径（不重算）才把旧行算进来", 1L, legacy.confirmed)
        rig.close()
    }

    // 重启：重算是查询侧现算、无任何落盘或进程内状态——重启后旧行仍按当前来源的时间判范围。
    @Test
    fun `after a restart legacy rows still gate by the current source time`() = runTest {
        val rig1 = Rig(this)
        val p1 = rig1.photo(1, generation = 1, dateAdded = today - 86_400)
        oldRow(rig1, 1, p1.snapshot.sourceVersion, 7, storedDateAddedSec = today)
        rig1.media.since = today
        rig1.trigger()
        assertEquals(emptyList<Long>(), rig1.delivery.deliveredMediaIds)
        rig1.close()

        // 进程 2：order 表还是那行旧行，引擎、来源读取全是新的——判定不得依赖上一进程的内存状态。
        val rig2 = Rig(this)
        val p2 = rig2.photo(1, generation = 1, dateAdded = today - 86_400)
        oldRow(rig2, 1, p2.snapshot.sourceVersion, 7, storedDateAddedSec = today)
        rig2.media.since = today
        rig2.trigger()
        assertEquals("重启后同样在范围外", emptyList<Long>(), rig2.delivery.deliveredMediaIds)
        assertEquals(OrderState.PENDING, rig2.state(1))
        assertEquals("没有要传的：不起前台服务", 0, rig2.foreground.acquires)
        rig2.close()
    }

    // ---------------------------------------------------------------- 多来源与撤权（组合源经 rig 的 mediaOverride）

    @get:Rule
    val tmp = TemporaryFolder()

    /** folder 段装饰器：可切换撤权（readInScope / lookup / existingIds 抛 SourceUnavailable）。 */
    private class SwitchableFolder(private val wrap: com.hawkeyexb.ppass.backup.order.MediaSnapshotSource) :
        com.hawkeyexb.ppass.backup.order.MediaSnapshotSource by wrap {
        var revoked = false
        override fun <R> readInScope(afterId: Long, block: (Sequence<com.hawkeyexb.ppass.backup.order.MediaSnapshot>) -> R): R {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.readInScope(afterId, block)
        }
        override fun lookup(mediaId: Long): com.hawkeyexb.ppass.backup.order.MediaDetails? {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.lookup(mediaId)
        }
        override fun existingIds(mediaIds: Collection<Long>): Set<Long>? {
            if (revoked) throw SourceUnavailableException("folder permission revoked")
            return wrap.existingIds(mediaIds)
        }
    }

    // 多来源：目录段的旧行也走同一条组合 lookup 重算（bit 62 路由到目录来源），与相册段同一判据；
    // 范围内的新目录素材端到端仍通。反证：目录旧行按 stored 判 → 老文件被补传，红。
    @Test
    fun `old folder rows recalc through the composite lookup like album rows`() = runTest {
        val root = tmp.newFolder("media-root")
        val registry = FolderRegistry(File(tmp.root, "registry.json"))
        registry.addFolder("file://tree", "media-root")
        File(root, "IMG_9.jpg").writeText("nine") // 老照片：拍摄时间在起点前
        File(root, "IMG_10.jpg").writeText("ten") // 新照片：拍摄时间在范围内
        // captureAtMs 是 epoch 毫秒：正值才被当成拍摄时间（≤0 会回退到文件 mtime——那正是要防的旧口径）。
        val captureOldMs = 500_000L // 500 秒 < 起点 1_000 秒：范围外
        val captureNewMs = today * 1000 + 5_000 // 1_005 秒 ≥ 起点：范围内
        val folder = FolderMediaSnapshotSource(
            registry,
            captureAtMs = { _, file -> if (file.relativePath == "IMG_9.jpg") captureOldMs else captureNewMs },
        ) { FileFolderTree(root) }
        val album = com.hawkeyexb.ppass.backup.order.FakeMedia()
        val composite = CompositeMediaSnapshotSource(album, folder)
        val bucket = registry.allRecords().single().bucketId
        // 相册集合放宽到目录 bucket（生产 = effectiveScope 的合并口径），时间判定走组合源重算。
        val rig = Rig(this, mediaOverride = composite, primaryMedia = album, inScopeBuckets = setOf(bucket), folderDiscovery = { composite.readFolderInScope() })
        advanceUntilIdle() // start 的初始 refreshPending（此刻范围无时间条件、目录空）

        // 登记时分配的 ID 是确定的：第一来源 bucket = flag|1，文件项按名字序分配（enumerate 排序）——
        // "IMG_10.jpg" < "IMG_9.jpg"，所以 IMG_10 = flag|2、IMG_9 = flag|3（见 FolderRegistry / FileFolderTree.walk）。
        val img10 = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 2L
        val img9 = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 3L
        // 导入桩的字节镜像：bucket 用目录 bucket（FakeMedia 的 scope 只有相册段 → 主段不会重复输出它）。
        rig.media.put(FakePhoto(img9, 100L, 4L, "nine", 0L, bucketId = bucket, dateAdded = today - 86_400))
        rig.media.put(FakePhoto(img10, 101L, 3L, "ten", 0L, bucketId = bucket, dateAdded = today))

        rig.store.markScanDirty()
        rig.media.since = today
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(
            "入册结果与预测一致",
            mapOf("IMG_9.jpg" to img9, "IMG_10.jpg" to img10),
            registry.allRecords().single().items.values.associate { it.relativePath to it.mediaId },
        )
        assertEquals("范围内的新目录素材端到端仍通", listOf(img10), rig.delivery.deliveredMediaIds)

        // 升级前的目录旧行：旧口径 DATE_ADDED = 今天入册。
        val ver9 = composite.lookup(img9)!!.snapshot.sourceVersion
        oldRow(rig, img9, ver9, bucket, storedDateAddedSec = today)
        rig.trigger()
        assertEquals("目录旧行按拍摄时间在范围外：不补传", listOf(img10), rig.delivery.deliveredMediaIds)
        assertEquals("原样留着，不误删", OrderState.PENDING, rig.state(img9))
        rig.close()
    }

    // 撤权：门槛处的重算 lookup 沿组合源抛 SourceUnavailable → 整轮进 WAITING/sourceUnavailable：
    // 不起前台服务、没有交付、旧行不打源缺失（不误传、不误删）。反证：吞掉撤权异常退回 stored →
    // 旧行被当成范围内，起前台服务走进导入才失败，红。
    @Test
    fun `a revoked folder with a legacy row waits at the gate without mislabeling`() = runTest {
        val root = tmp.newFolder("media-root-revoke")
        val registry = FolderRegistry(File(tmp.root, "registry-revoke.json"))
        registry.addFolder("file://tree", "media-root-revoke")
        File(root, "IMG_9.jpg").writeText("nine")
        // captureAtMs 是 epoch 毫秒：正值才被当成拍摄时间（≤0 会回退到文件 mtime——那正是要防的旧口径）。
        val captureOldMs = 500_000L // 500 秒 < 起点 1_000 秒：范围外
        val raw = FolderMediaSnapshotSource(
            registry,
            captureAtMs = { _, _ -> captureOldMs },
        ) { FileFolderTree(root) }
        val folder = SwitchableFolder(raw)
        val album = com.hawkeyexb.ppass.backup.order.FakeMedia()
        val composite = CompositeMediaSnapshotSource(album, folder)
        val bucket = registry.allRecords().single().bucketId
        val rig = Rig(this, mediaOverride = composite, primaryMedia = album, inScopeBuckets = setOf(bucket), folderDiscovery = { composite.readFolderInScope() })
        advanceUntilIdle()

        val img9 = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG or 2L
        rig.media.put(FakePhoto(img9, 100L, 4L, "nine", 0L, bucketId = bucket, dateAdded = today - 86_400))

        rig.store.markScanDirty()
        rig.media.since = today
        rig.trigger(TriggerReason.APP_FOREGROUND) // 入册：IMG_9 按拍摄时间在范围外，不建行
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)

        val ver9 = composite.lookup(img9)!!.snapshot.sourceVersion
        oldRow(rig, img9, ver9, bucket, storedDateAddedSec = today) // 旧行 stored 说在范围内

        val acquiresBefore = rig.foreground.acquires // 入册那轮（有扫描活）合法起过一次前台服务，取基线再比
        folder.revoked = true
        rig.trigger(TriggerReason.MEDIA_CHANGE) // 非对账轮：重算在门槛处（countTodo / 全量差集）即抛
        assertEquals("撤权：整轮等待", WaitReason.SOURCE_UNAVAILABLE, rig.control.wait)
        assertEquals("门槛处就等待：不起前台服务", acquiresBefore, rig.foreground.acquires)
        assertEquals("没有交付", emptyList<Long>(), rig.delivery.deliveredMediaIds)
        assertEquals("不误删：旧行不打源缺失", OrderState.PENDING, rig.state(img9))
        assertFalse(rig.store.currentForMedia(img9)!!.sourceMissing)

        // 反证基准：恢复授权 → 门槛正常放行判定，等待清掉；旧行仍按重算在范围外，不补传。
        folder.revoked = false
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(null, rig.control.wait)
        assertEquals(OrderState.PENDING, rig.state(img9))
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)
        rig.close()
    }
}
