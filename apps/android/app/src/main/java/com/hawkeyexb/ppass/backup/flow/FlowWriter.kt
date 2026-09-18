// MOB-88: Flow 状态的单写者。
//
// 改造前：账本的正确性全靠外面一把 `flowTriggerLock`，而且靠每个调用方
// **记得**去拿。7 个入口记住 5 个，漏掉的两个原生回调就是 #107（同一队头
// 双发）；另有四条路径（审计外发、配对代号刷新、构造段对账、读操作里的
// 补写）结构上拿不到那把锁。
//
// 改造后：所有状态变更都是投给这一个线程的 action，顺序 reduce。并发不是
// 被锁住的，是**不存在**。漏拿锁这件事没有了，因为没有锁。
package com.hawkeyexb.ppass.backup.flow

import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicReference

/**
 * 一条「已发生的事实」，不是命令。reducer 拿事实算新状态；副作用（算哈希、
 * 注册原生凭据、发 offer、停原生传输）由状态迁移触发，在写者线程之外跑。
 */
sealed interface FlowAction {
    /** 进程启动：把上一条进程life遗留的租约降级回 QUEUED。 */
    data object ReconcileProcessStart : FlowAction

    /** MOB-53 的一次性 completedAt 迁移（改造前藏在 `load()` 里）。 */
    data object MigrateCompletedAt : FlowAction

    /** 配对代号校正：与当前代号不一致时整份重置账本。 */
    data class EnsurePairingEpoch(val epoch: PairingEpoch) : FlowAction

    /** 唤醒：记下「要发现」这个意图，然后跑一轮。 */
    data class Wake(val constraintsSatisfied: Boolean) : FlowAction

    /** 只记下范围补扫这件事，不跑——由后续的调度唤醒去执行。 */
    data object ScopeBackfill : FlowAction

    /** 范围变更后的补扫 + 立刻跑一轮。 */
    data class ScopeBackfillAndWake(val constraintsSatisfied: Boolean) : FlowAction

    data object Pause : FlowAction

    data class Continue(val constraintsSatisfied: Boolean) : FlowAction

    data object RetryFailed : FlowAction

    data class CancelCurrentRound(val roundId: String) : FlowAction

    data object RestoreAllCancelledRounds : FlowAction

    /** 原生回调：源文件在发出去之前消失了。 */
    data object SkipMissingSource : FlowAction

    /** 原生回调：这次投递永久失败。 */
    data object RecordPermanentFailure : FlowAction

    /** 原生回调：桌面端确认收下了。 */
    data class AcceptReceipt(val receipt: CompletionReceipt) : FlowAction

    /** 算完哈希后回填——改造前是交付端在自己的线程上直接写账本。 */
    data class RecordContentHash(val item: TransferItem) : FlowAction

    /** 审计事件已被桌面端确认，可以从 outbox 里删掉。 */
    data class AcknowledgeAuditEvents(val eventIds: Set<String>) : FlowAction
}

/**
 * 副作用的出口。
 *
 * 默认 [InlineFlowEffects] 就地执行，等价于改造前的同步语义——现有 JVM
 * 测试的断言写法因此一行都不用改。生产接的是写者线程之外的执行器：算哈希
 * 是整文件读 + BLAKE3，几十秒到分钟级，绝不能占着状态决策的线程（改造前
 * 它就占着那把全局锁，见 #134）。
 */
fun interface FlowEffectSink {
    fun submit(effect: () -> Unit)
}

object InlineFlowEffects : FlowEffectSink {
    override fun submit(effect: () -> Unit) = effect()
}

/**
 * 单写者：一个线程 + 一条队列 + 一份内存权威状态。
 *
 * 线程归属同时是账本的写入门禁（[SingleThreadLedgerWrites]）——绕过 writer
 * 的写入当场抛异常，而不是像改造前那样静默覆盖。
 */
class FlowWriter private constructor(
    private val executor: java.util.concurrent.ExecutorService,
    val thread: Thread,
) {
    private val handler = AtomicReference<((FlowAction) -> Unit)?>(null)

    /** 由 [AndroidFlowRuntime] 在 runner 就绪后接上。 */
    fun bind(reduce: (FlowAction) -> Unit) {
        check(handler.compareAndSet(null, reduce)) { "flow writer already bound" }
    }

    fun dispatch(action: FlowAction): Future<*> = executor.submit {
        val reduce = handler.get() ?: return@submit
        try {
            reduce(action)
        } catch (failure: Throwable) {
            // 一条 action 失败不能让写者线程死掉——后面的 action 还要跑。
            // 但绝不静默：这类异常是本卡最想暴露的东西。
            Log.e("PPassFlowWriter", "flow action failed: $action", failure)
        }
    }

    /** 等这条 action 落地。用于启动引导、以及需要「写完才能继续」的副作用。 */
    fun dispatchAndAwait(action: FlowAction) {
        if (Thread.currentThread() === thread) {
            // 写者线程上再投给自己会死锁——直接执行，顺序语义不变。
            handler.get()?.invoke(action)
            return
        }
        runCatching { dispatch(action).get() }
            .onFailure { Log.e("PPassFlowWriter", "awaiting flow action failed: $action", it) }
    }

    /**
     * 把一段状态操作放到写者线程上同步执行。
     *
     * 只给引导与测试用——业务路径一律走 [dispatch]，因为 action 才是可读、
     * 可留痕、可校验前提的那个形式。
     */
    fun runOnWriter(task: () -> Unit) {
        if (Thread.currentThread() === thread) {
            task()
            return
        }
        executor.submit(task).get()
    }

    fun shutdown() = executor.shutdownNow()

    companion object {
        fun start(name: String): FlowWriter {
            val threadRef = AtomicReference<Thread>()
            val executor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, name).also { threadRef.set(it) }
            }
            // 强制把线程创建出来：写入门禁要拿它的引用，而账本在 runner
            // 之前就要构造好。
            executor.submit { }.get()
            return FlowWriter(executor, requireNotNull(threadRef.get()) { "single writer thread was not created" })
        }
    }
}
