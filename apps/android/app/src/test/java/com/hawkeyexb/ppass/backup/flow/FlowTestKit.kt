// ARCH-13 (#417) → #413: 逐张循环契约测试用的假端口。全部在 kotlinx-coroutines-test 的虚拟时间里跑。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.FakeMedia
import com.hawkeyexb.ppass.backup.order.FakePhoto
import com.hawkeyexb.ppass.backup.order.InMemoryOrderStore
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.VolumeState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle

/** 传输脚本：按 orderId 或按顺序给结局；[hold] 为 true 时挂起直到被放行或被取消。 */
class FakeDelivery : ItemDelivery {
    val requests = mutableListOf<DeliveryRequest>()
    val discarded = mutableListOf<Long>()
    val cancelled = mutableListOf<Long>()

    /** 下一次（及之后每次）传输的结局；为空时默认 Confirmed。 */
    val script = ArrayDeque<(DeliveryRequest) -> DeliveryOutcome>()

    /** 为 true 时 deliver 挂起在 [gate] 上。 */
    var hold = false
    var gate = CompletableDeferred<Unit>()

    /** 每次 deliver 开始时回调（例如「传输期间新拍一张」）。 */
    var onStart: (DeliveryRequest) -> Unit = {}

    /** 结局之前的进度脚本（可挂起、可在虚拟时间里 delay）；默认什么都不报。 */
    var progress: suspend (DeliveryRequest, (Long) -> Unit) -> Unit = { _, _ -> }

    val deliveredMediaIds get() = requests.map { it.details.snapshot.mediaId }

    override suspend fun deliver(request: DeliveryRequest, onProgress: (Long) -> Unit): DeliveryOutcome {
        requests += request
        onStart(request)
        try {
            if (hold) gate.await()
        } catch (c: kotlinx.coroutines.CancellationException) {
            cancelled += request.orderId
            throw c
        }
        progress(request, onProgress)
        onProgress(request.details.sizeBytes)
        val next = script.removeFirstOrNull() ?: { r -> confirmed(r) }
        return next(request)
    }

    override suspend fun discardPartial(orderId: Long, pairingEpoch: PairingEpoch) {
        discarded += orderId
    }

    fun release() {
        hold = false
        gate.complete(Unit)
        gate = CompletableDeferred()
    }

    companion object {
        fun confirmed(r: DeliveryRequest): DeliveryOutcome = DeliveryOutcome.Confirmed(
            CompletionReceipt(r.orderId, "receipt-${r.orderId}", r.pairingEpoch, r.contentHash, r.leaseToken),
        )
    }
}

class FakeForeground(private val control: FlowControl) : ForegroundLease {
    var acquires = 0
    var releases = 0
    var grant = true
    var held = false

    /** #413：受阻原因不是闸门——每次 acquire 都真的调一次 startForegroundService；成功就清掉原因。 */
    var startForegroundServiceCalls = 0

    override suspend fun acquire(): Boolean {
        acquires++
        startForegroundServiceCalls++
        held = grant
        if (grant) control.clearFgsBlock()
        return grant
    }

    override fun isHeld(): Boolean = held

    override fun renew() = Unit

    /** 每次 FGS 通知刷新（生产里是一次 NotificationManager.notify）。 */
    val updates = mutableListOf<LoopStatus>()

    /** 与 [updates] 一一对应的（虚拟）时刻。 */
    val updateTimes = mutableListOf<Long>()
    var clock: () -> Long = { 0L }

    override fun update(status: LoopStatus) {
        updates += status
        updateTimes += clock()
    }

    override fun release() {
        releases++
        held = false
    }
}

class FakeScheduler : WakeScheduler {
    var unreachableProbes = 0
    var probesCancelled = 0
    val constraintWakes = mutableListOf<WaitReason>()

    override fun scheduleUnreachableProbes() {
        unreachableProbes++
    }

    override fun cancelUnreachableProbes() {
        probesCancelled++
    }

    override fun scheduleWhenConditionsMet(reason: WaitReason) {
        constraintWakes += reason
    }
}

class FakeControl : FlowControl {
    var pausedFlag = false
    var block: FgsBlockReason? = null
    var wait: WaitReason? = null
    override fun waitReason() = wait
    override fun setWaitReason(reason: WaitReason?) {
        wait = reason
    }
    var ack = 0L
    override fun paused() = pausedFlag
    override fun setPaused(paused: Boolean) {
        pausedFlag = paused
    }
    override fun fgsBlock() = block
    override fun recordFgsBlock(reason: FgsBlockReason) {
        if (block == null) block = reason
    }
    override fun clearFgsBlock() {
        block = null
    }
    override fun missingSourceAckAt() = ack
    override fun setMissingSourceAckAt(atMs: Long) {
        ack = atMs
    }
}

/**
 * 假的 [MediaImporter]：导入 = 读 FakeMedia 的内容（假 hash），照片没了 → SourceMissing。
 * 计数：每次导入就是一次「读文件」；[failures] 非空时按顺序抛。
 */
internal class FakeImporter(private val media: FakeMedia) : MediaImporter {
    val imported = mutableListOf<Long>()
    val released = mutableListOf<String>()
    val failures = ArrayDeque<Exception>()

    /** MediaStore 还列着、文件读不到的照片。 */
    val unreadable = mutableSetOf<Long>()

    /** 覆盖某张照片导入出来的 hash（模拟「中断期间被编辑、MediaStore 版本没跟上」）。 */
    val hashOverride = mutableMapOf<Long, String>()

    override fun import(mediaId: Long, contentUri: String, dataPath: String?): ImportResult {
        imported += mediaId
        failures.removeFirstOrNull()?.let { throw it }
        if (mediaId in unreadable) return ImportResult.SourceMissing
        val photo = media.photos.singleOrNull { it.mediaId == mediaId } ?: return ImportResult.SourceMissing
        return ImportResult.Imported(hashOverride[mediaId] ?: photo.hash, photo.size, byReference = true)
    }

    override fun serve(lease: ProviderLease): String = "ticket-${lease.orderId}"

    override fun release(contentHash: String) {
        released += contentHash
    }
}

/**
 * 一套装好的引擎。[media] 默认范围是 bucket 7；照片内容即 hash 源（FakeMedia）。
 * [cursors] 为 true（默认）时预置 G = (0, 0)、getVersion 不变——视为「装好之后一直在跑」，只有显式置脏才扫描。
 */
internal class Rig(test: TestScope, cursors: Boolean = true) {
    val dispatcher = StandardTestDispatcher(test.testScheduler)
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val testScope = test
    var now = 1_000L
    val store = InMemoryOrderStore { now }
    val media = FakeMedia()
    val importer = FakeImporter(media)
    val delivery = FakeDelivery()
    val control = FakeControl()
    val foreground = FakeForeground(control).also { it.clock = { test.testScheduler.currentTime } }
    val scheduler = FakeScheduler()
    var probeResult: ProbeResult = ProbeResult.Reachable("e1")
    var probes = 0

    /** 探测开始时调用（可挂起：用来观察检查阶段）。 */
    var probeHook: suspend () -> Unit = {}
    var missingOnDesktop: Set<String> = emptySet()
    var presenceCalls = 0
    var conditions = Conditions()
    var epoch: PairingEpoch? = PairingEpoch("e1")
    val logs = mutableListOf<String>()

    init {
        if (cursors) store.saveVolumeState(VolumeState(LEGACY_VOLUME, 0L, 0L, "v1"))
    }

    val engine = FlowEngine(
        store = store,
        media = media,
        importer = importer,
        delivery = delivery,
        probe = DesktopProbe {
            probes++
            probeHook()
            probeResult
        },
        presence = RemotePresence { hashes -> presenceCalls++; hashes.filter { it in missingOnDesktop }.toSet() },
        foreground = foreground,
        scheduler = scheduler,
        control = control,
        conditions = { conditions },
        inScope = media::inScope,
        pairingEpoch = { epoch },
        scope = scope,
        io = dispatcher,
        log = FlowLogger { logs += it },
        clock = { now },
        monotonicClock = { test.testScheduler.currentTime },
    ).also { it.start() }

    fun photo(mediaId: Long, generation: Long, content: String = "c$mediaId", bucketId: Long = 7, volume: String = LEGACY_VOLUME): FakePhoto =
        FakePhoto(mediaId, 100 + mediaId, 10 + mediaId, content, generation, bucketId, volume).also { media.put(it) }

    fun order(p: FakePhoto, state: OrderState): Order =
        store.insert(NewOrder(p.mediaId, p.snapshot.sourceVersion, p.bucketId, p.hash, state, "e1"))

    fun state(mediaId: Long): OrderState? = store.currentForMedia(mediaId)?.state

    fun generation(): Long = store.volumeState(LEGACY_VOLUME)!!.generation

    fun settle() = testScope.advanceUntilIdle()

    fun trigger(reason: TriggerReason = TriggerReason.MEDIA_CHANGE) {
        engine.trigger(reason)
        settle()
    }

    fun pending(): Int = engine.view.value.pending

    /** 旧测试用：按契约的顺序「已暂停 → 弹窗拍边界 → 按边界取消」。返回写下的张数。 */
    fun cancelRemainingNow(): kotlinx.coroutines.Deferred<Int> = scope.async {
        control.pausedFlag = true
        engine.cancelRemaining(engine.remainingSnapshot()).await() ?: 0
    }

    fun close() = scope.cancel()
}
