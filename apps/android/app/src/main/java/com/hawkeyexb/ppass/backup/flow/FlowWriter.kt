// MOB-88 → ARCH-13 (#417): Flow 状态的单写者。
//
// 思想保留：所有状态变更都在**一个线程**上顺序发生，并发不是被锁住的，是不存在。
// 形式变了：改造前是「一条 action 队列 + reducer」，写的是整份 JSON 快照；现在是一个单线程
// CoroutineDispatcher，[FlowEngine] 的每条命令都在它上面跑，写的是 order 表的行事务。
// 写入门禁同样保留：[WriterGuardedOrderStore] 让任何绕过写者线程的写入当场抛，而不是静默竞争。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.backup.order.SkipResult
import com.hawkeyexb.ppass.backup.order.SkipTarget
import com.hawkeyexb.ppass.backup.order.VolumeState
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher

class FlowWriter private constructor(
    private val executor: java.util.concurrent.ExecutorService,
    val thread: Thread,
) {
    val dispatcher: CoroutineDispatcher = executor.asCoroutineDispatcher()

    fun shutdown() = executor.shutdownNow()

    companion object {
        fun start(name: String): FlowWriter {
            val threadRef = AtomicReference<Thread>()
            val executor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, name).also { threadRef.set(it) }
            }
            // 强制把线程创建出来：写入门禁要拿它的引用。
            executor.submit { }.get()
            return FlowWriter(executor, requireNotNull(threadRef.get()) { "single writer thread was not created" })
        }
    }
}

/** 写入线程归属门禁。 */
fun interface WriteGuard {
    fun assertAllowed()
}

/** 生产用：只有 [owner] 这一个线程可以写。 */
class SingleThreadWrites(private val owner: Thread) : WriteGuard {
    override fun assertAllowed() {
        val current = Thread.currentThread()
        check(current === owner) { "order store written off the single-writer thread: ${current.name} (owner=${owner.name})" }
    }
}

/** 读直通，写先过门禁。 */
class WriterGuardedOrderStore(private val delegate: OrderStore, private val guard: WriteGuard) : OrderStore by delegate {
    private inline fun <T> write(block: () -> T): T {
        guard.assertAllowed()
        return block()
    }

    override fun insert(order: NewOrder, advance: GenerationAdvance?, audit: AuditRecord?): Order = write { delegate.insert(order, advance, audit) }
    override fun transition(
        id: Long,
        expected: Set<OrderState>,
        to: OrderState,
        countAttempt: Boolean,
        advance: GenerationAdvance?,
        audit: AuditRecord?,
    ): Boolean = write { delegate.transition(id, expected, to, countAttempt, advance, audit) }
    override fun updateMapping(id: Long, mediaId: Long, sourceVersion: String, bucketId: Long): Boolean =
        write { delegate.updateMapping(id, mediaId, sourceVersion, bucketId) }
    override fun setContentHash(id: Long, hash: String): Boolean = write { delegate.setContentHash(id, hash) }
    override fun setSourceMissing(id: Long, missing: Boolean, audit: AuditRecord?): Boolean =
        write { delegate.setSourceMissing(id, missing, audit) }
    override fun delete(id: Long): Boolean = write { delegate.delete(id) }
    override fun skipByUser(targets: List<SkipTarget>, pairingEpoch: String, audit: AuditRecord?): SkipResult =
        write { delegate.skipByUser(targets, pairingEpoch, audit) }
    override fun saveVolumeState(state: VolumeState) = write { delegate.saveVolumeState(state) }
    override fun advanceGeneration(advance: GenerationAdvance) = write { delegate.advanceGeneration(advance) }
    override fun appendAudit(audit: AuditRecord) = write { delegate.appendAudit(audit) }
    override fun acknowledgeAudit(eventIds: Set<String>) = write { delegate.acknowledgeAudit(eventIds) }
    override fun claimOwner(ownerKey: String, idFloor: Long): Boolean = write { delegate.claimOwner(ownerKey, idFloor) }
}
