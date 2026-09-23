// ARCH-13 (#417): 逐张循环契约测试用的假端口。全部在 kotlinx-coroutines-test 的虚拟时间里跑。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.FakeMedia
import com.hawkeyexb.ppass.backup.order.FakePhoto
import com.hawkeyexb.ppass.backup.order.InMemoryOrderStore
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
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
        onProgress(request.details.sizeBytes)
        val next = script.removeFirstOrNull() ?: { r -> confirmed(r) }
        return next(request)
    }

    override fun discardPartial(orderId: Long, pairingEpoch: PairingEpoch) {
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

    /** 模拟真实实现：受阻事实在时，根本不调 startForegroundService。 */
    var startForegroundServiceCalls = 0

    override suspend fun acquire(): Boolean {
        acquires++
        if (control.fgsBlock() != null) return false
        startForegroundServiceCalls++
        held = grant
        return grant
    }

    override fun isHeld(): Boolean = held

    override fun renew() = Unit

    override fun update(status: LoopStatus) = Unit

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
 * 一套装好的引擎。[media] 默认范围是 bucket 7；照片内容即 hash 源（FakeMedia）。
 */
class Rig(test: TestScope) {
    val dispatcher = StandardTestDispatcher(test.testScheduler)
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val testScope = test
    var now = 1_000L
    val store = InMemoryOrderStore { now }
    val media = FakeMedia()
    val delivery = FakeDelivery()
    val control = FakeControl()
    val foreground = FakeForeground(control)
    val scheduler = FakeScheduler()
    var probeResult: ProbeResult = ProbeResult.Reachable("e1")
    var probes = 0
    var missingOnDesktop: Set<String> = emptySet()
    var presenceCalls = 0
    var conditions = Conditions()
    var epoch: PairingEpoch? = PairingEpoch("e1")
    val logs = mutableListOf<String>()

    val engine = FlowEngine(
        store = store,
        media = media,
        hasher = ContentHasher { id ->
            try {
                media.hash(id)
            } catch (e: java.io.FileNotFoundException) {
                throw SourceMissingException(e)
            }
        },
        delivery = delivery,
        probe = DesktopProbe { probes++; probeResult },
        presence = RemotePresence { hashes -> presenceCalls++; hashes.filter { it in missingOnDesktop }.toSet() },
        foreground = foreground,
        scheduler = scheduler,
        control = control,
        conditions = { conditions.copy(fgsBlocked = control.fgsBlock() != null) },
        inScope = media::inScope,
        pairingEpoch = { epoch },
        scope = scope,
        io = dispatcher,
        log = FlowLogger { logs += it },
        clock = { now },
    ).also {
        // 默认视为「已经全量对账过」（getVersion 没变），这样只有显式要求的触发才跑慢路径。
        store.saveVolumeState(com.hawkeyexb.ppass.backup.order.VolumeState(com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME, 0L, "v1"))
        it.start()
    }

    fun photo(mediaId: Long, generation: Long, content: String = "c$mediaId", bucketId: Long = 7, volume: String = com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME): FakePhoto =
        FakePhoto(mediaId, 100 + mediaId, 10 + mediaId, content, generation, bucketId, volume).also { media.put(it) }

    fun order(p: FakePhoto, state: OrderState): Order =
        store.insert(NewOrder(p.mediaId, p.snapshot.sourceVersion, p.bucketId, p.hash, state, "e1"))

    fun state(mediaId: Long): OrderState? = store.currentForMedia(mediaId)?.state

    fun settle() = testScope.advanceUntilIdle()

    fun trigger(reason: TriggerReason = TriggerReason.MEDIA_CHANGE) {
        engine.trigger(reason)
        settle()
    }

    fun close() = scope.cancel()
}
