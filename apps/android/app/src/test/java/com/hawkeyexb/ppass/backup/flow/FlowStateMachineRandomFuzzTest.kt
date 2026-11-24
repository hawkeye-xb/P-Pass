// #1992：Android 纯内存备份与连接状态机随机序列压测（Fuzzing）
// 测试范围：纯内存 FlowEngine 状态机在快速新增媒体、网络闪断/恢复、自动备份开关切换、
// 权限切换（Full/Partial/Denied/目录失效）、范围变更、对账交错下的核心不变量。
//
// 核心不变量：
// 1. 用户关闭自动备份开关期间，绝不触发新的自动媒体备份传输；
// 2. 最终恢复连通 + 权限 + 开启自动备份后跑一轮对账，范围内有效媒体 100% 收敛到 CONFIRMED 且无重复；
// 3. 状态机无死锁或矛盾非法态（收敛至 IDLE，pending 降为 0）。
// 失败时必须打印 seed 与完整事件追踪，以便 100% 稳定复现。

package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource
import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class SimplePRNG(seed: Long) {
    private var state: Long = if (seed == 0L) 0x123456789ABCDEF0L else seed

    fun nextLong(): Long {
        state = state * 6364136223846793005L + 1442695040888963407L
        return state
    }

    fun nextInt(upperBound: Int): Int {
        if (upperBound <= 0) return 0
        val v = (nextLong() ushr 32) % upperBound.toLong()
        return v.toInt()
    }

    fun nextBoolean(): Boolean = ((nextLong() ushr 63) and 1L) == 1L
}

class FlowStateMachineRandomFuzzTest {

    sealed class FuzzEvent {
        data class AddMedia(val id: Long, val bucket: Long) : FuzzEvent()
        data class RemoveMedia(val id: Long) : FuzzEvent()
        object NetworkDrop : FuzzEvent()
        object NetworkRecover : FuzzEvent()
        data class SetAutoBackup(val on: Boolean) : FuzzEvent()
        object SetPermissionFull : FuzzEvent()
        object SetPermissionPartial : FuzzEvent()
        object SetPermissionRevoked : FuzzEvent()
        object TriggerMediaChange : FuzzEvent()
    }

    /** 包装 FakeMedia，允许动态注入 SourceUnavailableException 模拟权限吊销 / 目录失效 */
    private class FuzzMediaSource(val base: com.hawkeyexb.ppass.backup.order.FakeMedia) : MediaSnapshotSource by base {
        var revoked: Boolean = false

        override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
            if (revoked) throw SourceUnavailableException("fuzz permission revoked")
            return base.readInScope(afterId, block)
        }

        override fun lookup(mediaId: Long): MediaDetails? {
            if (revoked) throw SourceUnavailableException("fuzz permission revoked")
            return base.lookup(mediaId)
        }

        override fun existingIds(mediaIds: Collection<Long>): Set<Long>? {
            if (revoked) throw SourceUnavailableException("fuzz permission revoked")
            return base.existingIds(mediaIds)
        }
    }

    @Test
    fun `random state machine interleaving preserves core invariants`() = runTest {
        val baseSeeds = listOf(199201L, 199202L, 199203L, 199204L, 199205L)
        val startNs = System.nanoTime()
        var totalDisabledEvents = 0
        for (seed in baseSeeds) {
            totalDisabledEvents += runFuzzIteration(seed)
        }
        assertTrue("Fuzz seeds must actually exercise SetAutoBackup(false) at least once", totalDisabledEvents > 0)
        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000L
        assertTrue("Fuzz test took too long: ${elapsedMs}ms > 5000ms", elapsedMs <= 5000L)
    }

    private fun kotlinx.coroutines.test.TestScope.runFuzzIteration(seed: Long): Int {
        val prng = SimplePRNG(seed)
        val trace = mutableListOf<String>()
        var disabledEventCount = 0

        var autoRuleOn = true
        val baseMedia = com.hawkeyexb.ppass.backup.order.FakeMedia()
        val fuzzSource = FuzzMediaSource(baseMedia)
        val rig = Rig(
            this,
            mediaOverride = fuzzSource,
            primaryMedia = baseMedia,
            inScopeOverride = { bucket, _ ->
                autoRuleOn && (bucket in (baseMedia.scope ?: emptySet()))
            }
        )

        // 跟踪不变量 ①：用户关闭自动备份期间是否被违规触发自动备份传输
        val illegalTransfersWhileDisabled = mutableListOf<Long>()
        rig.delivery.onStart = { req ->
            if (!autoRuleOn) {
                illegalTransfersWhileDisabled += req.details.snapshot.mediaId
            }
        }

        var nextPhotoId = 1L
        val existingPhotos = mutableListOf<Long>()
        var nextGeneration = 1L

        trace += "SEED=$seed START"

        for (step in 0 until 40) {
            val choice = prng.nextInt(10)
            val event: FuzzEvent

            when (choice) {
                0, 1, 2 -> { // 新增媒体 (30%)
                    val photoId = nextPhotoId++
                    val bucket = if (prng.nextBoolean()) 7L else 8L
                    rig.photo(photoId, generation = nextGeneration++, bucketId = bucket)
                    existingPhotos += photoId
                    event = FuzzEvent.AddMedia(photoId, bucket)
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.MEDIA_CHANGE)
                }
                3 -> { // 媒体被外部删除 (10%)
                    if (existingPhotos.isNotEmpty()) {
                        val idx = prng.nextInt(existingPhotos.size)
                        val photoId = existingPhotos.removeAt(idx)
                        rig.media.remove(photoId)
                        event = FuzzEvent.RemoveMedia(photoId)
                    } else {
                        event = FuzzEvent.TriggerMediaChange
                        rig.trigger(TriggerReason.MEDIA_CHANGE)
                    }
                    trace += "Step $step: $event"
                }
                4 -> { // 网络断开 (10%)
                    rig.probeResult = ProbeResult.Unreachable
                    event = FuzzEvent.NetworkDrop
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.NETWORK_CHANGE)
                }
                5 -> { // 网络恢复 (10%)
                    rig.probeResult = ProbeResult.Reachable()
                    rig.routeOk = true
                    event = FuzzEvent.NetworkRecover
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.DESKTOP_REACHABLE)
                }
                6 -> { // 自动备份开关切换 (10%)
                    val on = prng.nextBoolean()
                    if (!on) disabledEventCount++
                    autoRuleOn = on
                    rig.conditions = rig.conditions.copy(autoBackupEnabled = on)
                    event = FuzzEvent.SetAutoBackup(on)
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.APP_FOREGROUND)
                }
                7 -> { // 权限 Full / 范围扩充 (10%)
                    rig.media.scope = setOf(7L, 8L)
                    rig.fullMediaAccess = true
                    fuzzSource.revoked = false
                    event = FuzzEvent.SetPermissionFull
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.SCOPE_ADDED)
                }
                8 -> { // 权限 Partial / 范围受限 (10%)
                    rig.media.scope = setOf(7L)
                    rig.fullMediaAccess = false
                    fuzzSource.revoked = false
                    event = FuzzEvent.SetPermissionPartial
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.MEDIA_CHANGE)
                }
                9 -> { // 权限失效 / 目录不可用 (10%)
                    fuzzSource.revoked = true
                    event = FuzzEvent.SetPermissionRevoked
                    trace += "Step $step: $event"
                    rig.trigger(TriggerReason.MEDIA_CHANGE)
                }
                else -> {
                    event = FuzzEvent.TriggerMediaChange
                    rig.trigger(TriggerReason.MEDIA_CHANGE)
                }
            }

            // 验证不变量 ①：用户关闭自动备份开关期间绝不触发新的备份传输
            assertTrue(
                "Invariant 1 violated: transfers occurred while auto backup was disabled! Seed: $seed, transfers: $illegalTransfersWhileDisabled\nTrace:\n${trace.joinToString("\n")}",
                illegalTransfersWhileDisabled.isEmpty()
            )
        }

        // ==================== 最终收敛阶段 ====================
        trace += "FINALIZING: restoring ideal conditions for convergence"

        // 恢复全部理想状态：开启自动备份、网络可达、权限 Full、重置异常抛出
        autoRuleOn = true
        rig.conditions = rig.conditions.copy(
            paired = true,
            autoBackupEnabled = true,
            wifiOnly = false,
            onUnmetered = true,
            batteryLow = false
        )
        rig.probeResult = ProbeResult.Reachable()
        rig.routeOk = true
        rig.media.scope = setOf(7L, 8L)
        rig.fullMediaAccess = true
        fuzzSource.revoked = false
        rig.control.pausedFlag = false

        // 触发 scopeAdded（置脏扫描）与 periodic 兜底对账确保充分发现与收敛
        rig.trigger(TriggerReason.SCOPE_ADDED)
        rig.trigger(TriggerReason.PERIODIC)

        // 验证不变量 ②：范围内所有存在且未删除的有效媒体，最终 100% 收敛到 CONFIRMED，且无重复传输请求
        val deliveredMediaIds = rig.delivery.deliveredMediaIds
        val seenDelivered = mutableSetOf<Long>()
        val duplicateDeliveries = mutableListOf<Long>()

        for (mediaId in deliveredMediaIds) {
            if (mediaId in seenDelivered) {
                duplicateDeliveries += mediaId
            }
            seenDelivered += mediaId
        }

        assertTrue(
            "Invariant 2 violated: duplicate delivery requests found for same media! Seed: $seed, duplicates: $duplicateDeliveries\nTrace:\n${trace.joinToString("\n")}",
            duplicateDeliveries.isEmpty()
        )

        val expectedPhotos = rig.media.photos.filter { rig.media.inScope(it.bucketId, it.dateAdded) }
        for (photo in expectedPhotos) {
            val order = rig.store.currentForMedia(photo.mediaId)
            assertTrue(
                "Invariant 2 violated: in-scope photo ${photo.mediaId} had no order! Seed: $seed\nTrace:\n${trace.joinToString("\n")}",
                order != null
            )
            assertEquals(
                "Invariant 2 violated: in-scope photo ${photo.mediaId} was not confirmed (state=${order?.state})! Seed: $seed\nTrace:\n${trace.joinToString("\n")}",
                OrderState.CONFIRMED,
                order?.state
            )
        }

        // 验证不变量 ③：状态机收敛，无死锁与未决悬挂
        val pending = rig.pending()
        assertEquals(
            "Invariant 3 violated: pending items remaining after convergence! pending=$pending, Seed: $seed\nTrace:\n${trace.joinToString("\n")}",
            0,
            pending
        )
        assertEquals(
            "Invariant 3 violated: engine did not settle to IDLE! state=${rig.engine.view.value.state}, Seed: $seed\nTrace:\n${trace.joinToString("\n")}",
            GlobalState.IDLE,
            rig.engine.view.value.state
        )

        rig.close()
        return disabledEventCount
    }
}
